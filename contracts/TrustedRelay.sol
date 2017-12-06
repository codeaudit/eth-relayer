// NOTE: THIS IS NOT YET FUNCTIONAL!!!

// This is a proof-of-concept of a token relay between chains.
// A user deposits tokens to this contract and chooses the destination chain.
// The relayer is incentivized with a small fee to replay the message on the
// desired chain.
// A separate chain must have a token that maps 1:1 to the current chain.
// In the case of a new chain, the relayer contract would initially own all
// the tokens (but they would be locked up).
pragma solidity ^0.4.18;

import "tokens/Token.sol";  // truffle package (install with `truffle install tokens`)
import "tokens/HumanStandardToken.sol";

contract TrustedRelay {

  //============================================================================
  // GLOBAL VARIABLES
  //============================================================================

  // Fees mapping from chainId=>fee
  // These are the minimum fees. chaindId=>token where token is the address on
  // this chain (the originating chain).
  mapping (uint => mapping(address => uint)) public fees;
  uint public chainId;
  // Number of seconds worth of difference we will "tolerate" the default is
  // 10 minutes. If a message is sent that is >tolerance old, it will be rejected.
  uint public tolerance = 600;
  mapping (address => bool) owners;
  mapping (address => mapping(address => uint)) balances;
  // Maps originating chain id and token address to new address. This requires
  // tokens be recreated on this chain before any such mappings can occur.
  mapping (uint => mapping(address => address)) tokens;
  // An outside token that maps to ether given a chainId. A value of 0 indicates
  // there is no eth token on that chain.
  mapping (uint => address) ethToken;
  // whether ether is allowed on this chain for deposits. This would be true
  // if this is a child chain that maps to an ERC20 token on another chain.
  bool public etherAllowed;
  // If any deposits fail and need to be undone, that can only be done once.
  // They are identified by the hash that is signed to deposit in the first place.
  mapping (bytes32 => bool) undone;
  // To prevent replays, record when a deposit happens and when a relay happens.
  mapping (bytes32 => bool) played;

  //============================================================================
  // EVENTS AND INIT
  //============================================================================

  event Deposit(address indexed sender, address indexed token, uint indexed toChain,
    uint amount, uint fee, uint tsIncl, uint tsNow);
  event UndoDeposit(address indexed sender, address indexed token, uint indexed toChain,
    uint amount, uint fee, uint tsIncl, uint tsNow);
  event RelayedDeposit(address indexed sender, address indexed oldToken, address newToken,
    uint indexed fromChain, uint amount, uint fee, uint tsIncl, uint tsNow);

  event NewOwner(address newOwner, uint timestamp);
  event RemoveOwner(address oldOwner, uint timestamp);

  function TrustedRelay() public {
    owners[msg.sender] = true;
    NewOwner(msg.sender, now);
  }

  // This can only be done once!
  function setChainId(uint id) public isOwner {
    assert(chainId == 0);
    chainId = id;
  }


  //============================================================================
  // DEPOSITS AND RELAYS
  //============================================================================

  // Make a deposit to another chain. This locks up the tokens on this chain.
  // They will appear in the other chain for withdrawal.
  // data = [ fee, timestamp ]
  function depositERC20(bytes32 m, uint8 v, bytes32 r, bytes32 s, address token, uint amount, uint toChain, uint[2] data)
  public payable {
    assert(data[1] >= now && data[1] - now < tolerance); // check timestamp
    assert(data[0] >= fees[toChain][token]);  // Make sure the fee is high enough
    address sender = hashChecks(m, v, r, s, [token, msg.sender], amount, [chainId, toChain], data);
    Token t;
    t = Token(token);
    t.transferFrom(sender, address(this), amount);
    Deposit(sender, token, toChain, amount, data[0], data[1], now);

    played[m] = true;
  }

  // This may map to an eth token on a different chain. If it doesn't, the call
  // will fail on the other end.
  // In the case of ether, no amount is specified - it is inferred from msg.value
  // chainIds = [ originating, destination]
  // data = [ fee, timestamp ]
  function depositEther(bytes32 m, uint8 v, bytes32 r, bytes32 s, uint toChain, uint[2] data)
  public payable {
    assert(data[1] > now && data[1] - now < tolerance);
    assert(data[0] >= fees[toChain][address(0)]);  // Make sure the fee is high enough
    assert(etherAllowed == true);
    assert(msg.value > 0);
    // Make sure there is an ether token on the desired chain
    assert(ethToken[toChain] != address(0));
    address sender = hashChecks(m, v, r, s, [address(0), msg.sender], msg.value, [chainId, toChain], data);
    Deposit(sender, address(0), toChain, msg.value, data[0], data[1], now);
    played[m] = true;
  }

  // Relayer only
  // Unfreeze tokens on this chain.
  // addrs = [ token, originalSender ]
  // data = [ fee, timestamp ]
  function relayDepositERC20(bytes32 m, uint8 v, bytes32 r, bytes32 s, address[2] addrs, uint amount, uint fromChain, uint[2] data)
  isOwner public {
    address sender = makeChecks(m, v, r, s, addrs, amount, [fromChain, chainId], data);
    if (ethToken[fromChain] == addrs[0]) {
      // If this is an eth token, reward ether on this chain
      sender.transfer(amount-data[0]);
      msg.sender.transfer(data[0]);
      RelayedDeposit(sender, addrs[0], address(0), fromChain, amount, data[0], data[1], now);
    } else {
      // Otherwise reward a token
      Token t;
      t = Token(tokens[fromChain][addrs[0]]);
      assert(t.balanceOf(address(this)) >= amount);
      t.transfer(sender, amount-data[0]);
      t.transfer(msg.sender, data[0]);
      RelayedDeposit(sender, addrs[0], tokens[fromChain][addrs[0]], fromChain, amount, data[0], data[1], now);
    }

    played[m] = true;
  }

  // If there is not a matching token on the other chain or some other error
  // occurred, the relayer can bring it back to this chain.
  // addrs = [ token, originalSender ]
  // sig = [ hash, r, s ]
  // data = [ fee, timestamp ]
  function undoDepositERC20(bytes32[3] sig, uint8 v, address[2] addrs, uint amount, uint toChain, uint[2] data)
  isOwner public {
    assert(played[sig[0]] = true);
    address sender = makeChecks(sig[0], v, sig[1], sig[2], addrs, amount, [chainId, toChain], data);
    Token t;
    t = Token(addrs[0]);
    t.transfer(sender, amount);
    UndoDeposit(sender, addrs[0], toChain, amount, data[0], data[1], now);
    undone[sig[0]] = true;
  }

  // Recreate a new token based on the parameters of the old one. This new token
  // only has basic ERC20 functionality and all tokens will be owned by this contract.
  // Anyone that deposits into the old chain will get an equivalent number of this
  // token withdrawn to their address in this chain by the relayer.
  function recreateERC20Token(address oldToken, uint oldChainId, uint256 initialAmount, string tokenName, uint8 decimalUnits, string tokenSymbol)
  isOwner public {
    HumanStandardToken newToken = new HumanStandardToken(initialAmount, tokenName, decimalUnits, tokenSymbol);
    tokens[oldChainId][oldToken] = newToken;
  }

  // This is for more complicated tokens with additional functionality. They must
  // be recreated before this can be called. It associates an old chain address
  // with this new token.
  function mapERC20Token(uint oldChainId, address oldToken, address newToken) public isOwner {
    tokens[oldChainId][oldToken] = newToken;
  }


  //============================================================================
  // OWNER ADMIN FUNCTIONS
  //============================================================================

  function addOwner(address newOwner) public isOwner {
    owners[newOwner] = true;
    NewOwner(newOwner, now);
  }

  function removeOwner(address oldOwner) public isOwner {
    owners[oldOwner] = false;
    RemoveOwner(oldOwner, now);
  }

  function changeEtherAllowed(bool allowed) public isOwner {
    etherAllowed = allowed;
  }

  function setTolerance(uint newTolerance) public isOwner {
    tolerance = newTolerance;
  }

  function setFee(uint chainId, address token, uint fee) public isOwner {
    fees[chainId][token] = fee;
  }



  //============================================================================
  // CONSTANT FUNCTIONS
  //============================================================================

  // addrs = [ token(originating), user ]
  // chainIds = [ originating, destination ]
  // data = [ fee, timestamp ]
  function makeChecks(bytes32 m, uint8 v, bytes32 r, bytes32 s, address[2] addrs, uint amount, uint[2] chainIds, uint[2] data)
  public constant returns(address) {
    address sender = hashChecks(m, v, r, s, addrs, amount, chainIds, data);
    address mappedToken = tokens[chainIds[0]][addrs[1]];
    assert(mappedToken != address(0));
    return sender;
  }

//    address sender = makeChecks(m, v, r, s, [token, msg.sender], amount, [chainId, toChain], data);
  function hashChecks(bytes32 m, uint8 v, bytes32 r, bytes32 s, address[2] addrs, uint amount, uint[2] chainIds, uint[2] data)
  public constant returns(address) {
    // Order of items:
    // <originating chainId>, <destination chainId>,
    // <originating token address>, <depositer address>
    // <amount of token deposited (atomic units)>,
    // <fee>, <timestamp>
    assert(m == keccak256(uint256(chainIds[0]), uint256(chainIds[1]), address(addrs[0]),
      uint256(amount), address(addrs[1]), uint256(data[0]), uint256(data[1])));

    assert(chainIds[0] == chainId);
    address sender = ecrecover(m, v, r, s);
    assert(address(addrs[1]) == address(sender));
    return sender;
  }


  function checkIsOwner(address owner) public constant returns (bool) {
    if (owners[owner] == true) { return true; }
    return false;
  }

  function getNow() public constant returns (uint) {
    return now;
  }

  function getTokenMapping(uint fromChain, address token) public constant returns (address) {
    return tokens[fromChain][token];
  }

  modifier isOwner() {
    assert(owners[msg.sender] == true);
    _;
  }

}