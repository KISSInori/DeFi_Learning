pragma solidity =0.5.16; // 只能是这个版本

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo; // 收取LP协议费的地址
    address public feeToSetter; // 拥有feeTo管理权限的管理员地址

    mapping(address => mapping(address => address)) public getPair; // token A -> token B -> pair ，对应两种代币组成的pair地址
    address[] public allPairs; // 所有的交易对合约地址，public会自动生成getter函数

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter; // 初始化管理员地址
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length; // 返回当前所有pair的长度，即当前拥有的池子数量
    }

    // 创建交易对（核心），输入两种代币的地址，返回创建的池子合约地址
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES'); // 必须是两种代币
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA); // 顺序从小到大，标准化处理，避免顺序不同造成的重复问题
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS'); // 0地址不可用作token，这里其实规避了两种代币，都不是0地址
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // 确保pair还未被创建
        
        // 为什么不使用new（create）？这里使用的是create2创建，可以在部署智能合约前预先计算出合约的部署地址
        bytes memory bytecode = type(UniswapV2Pair).creationCode; // 获取V2pair合约的创建字节码
        bytes32 salt = keccak256(abi.encodePacked(token0, token1)); // 获取salt用于在部署前确定池子pair的地址
        assembly { // 使用内联的原因是因为该solidity版本没有create2的语法糖，只能通过底层的EVM指令调用
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt) // 实现链上部署（以太币数额，实际的合约字节码起始位置offset，bytecode开头的32字节的合约字节码长度，代币地址编码得到的确定性salt）
        }

        IUniswapV2Pair(pair).initialize(token0, token1); // 初始化池子
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // 建立双向映射，方便查询地址
        allPairs.push(pair); // 新创建的pair添加到交易对列表
        emit PairCreated(token0, token1, pair, allPairs.length); // 触发事件
    }

    // 设置某地址用于开启手续费，必须由管理员控制
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    // 设置新的管理员地址，必须由管理员控制
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
