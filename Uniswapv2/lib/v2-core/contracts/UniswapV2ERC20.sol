pragma solidity =0.5.16;

import './interfaces/IUniswapV2ERC20.sol';
import './libraries/SafeMath.sol';

contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint; // 使用 SafeMath 扩展 uint 类型，替代直接使用 + - * /

    string public constant name = 'Uniswap V2'; // LP token的名字
    string public constant symbol = 'UNI-V2';   // LP token的符号
    uint8 public constant decimals = 18;        // LP token的精度
    uint  public totalSupply;                   // LP token的总供应量
    mapping(address => uint) public balanceOf;  // 某个地址持有的LP token的余额
    mapping(address => mapping(address => uint)) public allowance; // owner -> spender -> 授权额度

    bytes32 public DOMAIN_SEPARATOR; // Permit (EIP-2612) 支持
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor() public {
        uint chainId;
        assembly {
            chainId := chainid
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    // ERC-20 逻辑
    // 铸造LP token：1.增加池子LP token总供应量；2.增加某个地址的代币余额；3.0地址向该地址转账事件
    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    // 销毁LP token：1.减少对应地址的代币余额；2.减少总供应量；3.向0地址转账触发
    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    // owner授权spender代币的value额度
    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    // 转账逻辑：1，from地址余额减少；2.to地址余额增加value；3.触发事件
    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    // 外部接口，授权逻辑，授权spender花费value
    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    // 外部接口，转账逻辑，调用内部转账，把代币转账给to
    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    // 代理转账，如果不是无限授权需要先更新授权的额度，然后进行转账逻辑
    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    // 允许用户通过签名的方式离线授权spender，节省一次授权的链上操作
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED');
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',   // EIP-712 前缀
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s); // 验证签名
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE'); // 签名者为owner
        _approve(owner, spender, value); // 授权通过，调用_approve函数
    }
}
