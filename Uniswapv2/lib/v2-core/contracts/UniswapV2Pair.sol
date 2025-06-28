pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint; // 引入 SafeMath 来安全处理 uint 运算
    using UQ112x112 for uint224; // 引入 UQ112x112 固定精度库，用于价格累积计算（112.112 定点格式）

    // 固定最小流动性：首次 mint 会被永久锁定的 LP 代币数量（防止除以0攻击）
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // transfer() 函数选择器，用于低层调用 token 的 transfer
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory; // 工厂合约地址
    address public token0;  // 代币地址，已排序
    address public token1;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves，池子中代币的数量/储备量
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves，最新的区块链时间戳

    uint public price0CumulativeLast; // 两种代币最新的累计价格
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    // 重入锁，防止重入攻击
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // 返回当前储备量和最后更新时间戳
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // 安全调用 token 的 transfer 函数
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // 对某些返回 bool，或不返回任何值的 ERC20 兼容性做了兼容
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1); // 添加流动性（Mint）
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to); // 移除流动性（Burn）
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    ); // 执行交换（Swap）
    event Sync(uint112 reserve0, uint112 reserve1);  // 同步储备量（Sync）

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    // 为什么还要另外定义一个初始化函数，而不直接将 _token0 和 _token1在构造函数中作为入参进行初始化呢？
    // 这是因为用 create2 创建合约的方式限制了构造函数不能有参数。
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check，只允许工厂合约调用初始化函数
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    // 在每个区块开始的第一笔交易之前更新储备量
    // 这里的balance是当前合约代币的真实余额，reserve是上一次同步的储备量
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW'); // 确保余额不会超过uint112的最大值，防止溢出
        uint32 blockTimestamp = uint32(block.timestamp % 2**32); // 获取当前时间戳，使用uint32进行了截断为32位，保证类型相同
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // 溢出是被允许的，这里原因白皮书有说明
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) { // 不同区块下，分别累计两种代币的价格
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        // 更新储备量和最终时间戳，发出Sync事件供外部进行监听
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    // 正常每次可以交易收取手续费，但是太耗费gas, 所以只在每次添加mint和移除burn流动性的时候才进行手续费计算
    // 这里是的储备量是池子原本的储备量，还没有因为mint或者burn的操作进行更新
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0); // 不是0地址则说明开启协议费
        uint _kLast = kLast; // gas savings，定义在storage中的全局变量，上一次的k
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1)); // 当前池子储备量计算出的k
                uint rootKLast = Math.sqrt(_kLast); // 上一次的流动性k
                if (rootK > rootKLast) { // 当前的k>上一次的k，说明池子中的资产增加，可以分发协议费，下面是具体公式
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity); // 如果算出来的 LP token 数量 > 0，就铸造给 feeTo 地址
                }
            }
        } else if (_kLast != 0) { // 如果没开启协议费，并且k不为0，就重置其为0
            kLast = 0;
        }
    }

    // 添加流动性
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 根据池子现有的代币余额-原来的储备量得到mint的资产数量（添加流动性部分的资产）
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        // 计算协议费
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 添加流动性过程
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // 初始池子，第一次添加流动性，流动性为两种代币的数量相乘的平方根-最小流动性（1000）
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else { // 不是初始流动性提供者，根据两种代币添加的比例获取对应的LP token（按照值较小的那个来处理）
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity); // 发送流动性token

        _update(balance0, balance1, _reserve0, _reserve1); // 更新储备量和余额
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // 更新k值
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        // 获取代币余额情况
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)]; // 路由合约会将用户的流动性代币转到池子合约（此合约）

        // 计算协议费
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee

        // 计算代币可以被提取的数量，用户流动性占总流动性的比例，按照此比例提取代币数量
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity); // 销毁这些流动性代币
        // 给用户转账对应的代币
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        // 获取最新的池子的余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        // 更新余额和储备
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // 更新k值
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT'); // 必须有一种资产是作为输出的，要大于0
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings，获取池子当前的储备情况
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY'); // 确保池子的储备量足够进行输出

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO'); // 获取代币的地址不能是代币地址，要是其他合约或者用户地址

        // 乐观转账两种代币
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        // 使用回调函数callback，用户需要在这个函数中完成逻辑，接收代币
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);

        // 转账完成，获取池子目前的代币余额情况，根据余额和储备量就可以计算出输入的代币数量
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT'); // 防止白嫖，必须有至少一个输入
        { // 调整了保留{0,1}的作用域，避免堆栈太深的错误
          // 在恒定乘积不变的情况下，扣除0.3%的手续费（来自于输入）
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K'); // k值是不可以减少的，保证池子流动性充足
        }

        // 更新池子的储备量，累计价格
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);// 触发swap事件
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        // 计算余额和存储量的差值，将差值转给to，这可能是由于用户误操作造成的，因此这个函数可以将多出来的token转到指定的to地址
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    // 如果发生了直接的 token 转入/转出合约，但没有通过 swap() / mint() / burn()，reserve0/1 就不会更新
    // 此时 sync() 强制将储备更新为实际余额
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
