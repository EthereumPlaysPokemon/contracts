pragma solidity ^0.4.24;

/**
 * @title SafeMath
 * @dev Math operations with safety checks that throw on error
 */
library SafeMath {

  /**
  * @dev Multiplies two numbers, throws on overflow.
  */
  function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
    // Gas optimization: this is cheaper than asserting 'a' not being zero, but the
    // benefit is lost if 'b' is also tested.
    // See: https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522
    if (a == 0) {
      return 0;
    }

    c = a * b;
    assert(c / a == b);
    return c;
  }

  /**
  * @dev Integer division of two numbers, truncating the quotient.
  */
  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    // assert(b > 0); // Solidity automatically throws when dividing by 0
    // uint256 c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn't hold
    return a / b;
  }

  /**
  * @dev Subtracts two numbers, throws on overflow (i.e. if subtrahend is greater than minuend).
  */
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    assert(b <= a);
    return a - b;
  }

  /**
  * @dev Adds two numbers, throws on overflow.
  */
  function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
    c = a + b;
    assert(c >= a);
    return c;
  }
}

/**
 * @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".
 */
contract Ownable {
  address public owner;


  event OwnershipRenounced(address indexed previousOwner);
  event OwnershipTransferred(
    address indexed previousOwner,
    address indexed newOwner
  );


  /**
   * @dev The Ownable constructor sets the original `owner` of the contract to the sender
   * account.
   */
  constructor() public {
    owner = msg.sender;
  }

  /**
   * @dev Throws if called by any account other than the owner.
   */
  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }

  /**
   * @dev Allows the current owner to relinquish control of the contract.
   * @notice Renouncing to ownership will leave the contract without an owner.
   * It will not be possible to call the functions with the `onlyOwner`
   * modifier anymore.
   */
  function renounceOwnership() public onlyOwner {
    emit OwnershipRenounced(owner);
    owner = address(0);
  }

  /**
   * @dev Allows the current owner to transfer control of the contract to a newOwner.
   * @param _newOwner The address to transfer ownership to.
   */
  function transferOwnership(address _newOwner) public onlyOwner {
    _transferOwnership(_newOwner);
  }

  /**
   * @dev Transfers control of the contract to a newOwner.
   * @param _newOwner The address to transfer ownership to.
   */
  function _transferOwnership(address _newOwner) internal {
    require(_newOwner != address(0));
    emit OwnershipTransferred(owner, _newOwner);
    owner = _newOwner;
  }
}

contract EPPv2 is Ownable {
     using SafeMath for uint;
    // szabo = microether
    uint constant MIN_PAYMENT = 10 szabo;

    uint constant MIN_PAYMENT_PLAYER_NAME = 5 finney;
    uint constant MIN_PAYMENT_RIVAL_NAME = 1 finney;

    struct Account {
        uint balance;
        uint toOwner;
        uint lockedBalance;
        uint lockedAt;
        uint nonce;
    }

    mapping (address => Account) accounts;
    uint ownerBalance;
    uint lockPeriod;

    enum Button { Up, Down, Left, Right, A, B, Start, Select }

    event MoveMade(Button move, uint block, address player, uint value);
    event PlayerNameChange(address player, string name, uint value);
    event RivalNameChange(address player, string name, uint value);
    event Deposit(address player, uint balance);
    event Withdraw(address player, uint ownerAmount, uint nonce);

    modifier onlyUnlocked {
        require(!isLocked(msg.sender));
        _;
    }

    modifier onlyLocked {
        require(isLocked(msg.sender));
        _;
    }

    constructor(uint lockPeriodInBlocks) public {
        lockPeriod = lockPeriodInBlocks;
    }

    function changePlayerName(string name) public payable {
        require(msg.value >= MIN_PAYMENT_PLAYER_NAME);
        require(bytes(name).length > 0 && bytes(name).length <= 7);

        increaseOwnerBalance(msg.value);

        emit PlayerNameChange(msg.sender, name, msg.value);
    }

    function changeRivalName(string name) public payable {
        require(msg.value >= MIN_PAYMENT_RIVAL_NAME);
        require(bytes(name).length > 0 && bytes(name).length <= 7);

        increaseOwnerBalance(msg.value);

        emit RivalNameChange(msg.sender, name, msg.value);
    }

    // Make a move on-chain
    function makeMove(Button move) public payable {
        require(msg.value == 0 || msg.value >= MIN_PAYMENT);

        ownerBalance = ownerBalance.add(msg.value);

        emit MoveMade(move, block.number, msg.sender, msg.value);
    }

    // Deposit Ether into the payment channel, creating the account if
    // none exists yet
    function deposit() onlyUnlocked public payable {
        address player = msg.sender;
        uint amount = msg.value;

        // Create the account by setting the nonce to 1
        if (accounts[player].nonce == 0) {
            accounts[player].nonce = 1;
        }

        increaseBalance(player, amount);

        emit Deposit(player, balanceOf(player));
    }

    // Initiate a withdrawal with a lockup period
    // owner_amount: amount to transfer to the contract owner. The rest is
    // implicitly withdrawn.
    // The Withdraw message is emitted with the owner_amount, the owner
    // should check it for fraud
    function initiateWithdrawal(uint owner_amount) onlyUnlocked public {
        address player = msg.sender;

        initiateWithdrawalForPlayer(player, owner_amount);

        emit Withdraw(player, owner_amount, nonceOf(player));
    }

    // Complete a withdrawal that was initiated earlier
    function withdraw() public {
        address player = msg.sender;
        uint locked_at = lockedAt(player);

        // Check that they have a pending withdrawal
        require(locked_at > 0);
        require(locked_at <= block.number);

        // Check that the lock period has passed
        uint locked_blocks = block.number.sub(locked_at);
        require(locked_blocks >= lockupPeriod());

        // Zero-out locked balance
        uint amount = lockedBalanceOf(player);
        decreaseLockedBalance(player, amount);

        // Clear locking fields and update nonce
        accounts[player].lockedAt = 0;
        accounts[player].toOwner = 0;
        incrementNonce(player);

        // Transfer the locked balance to the player
        player.transfer(amount);
    }

    // Force a withdrawal by proving that the player has committed to sending
    // 'amount' of their balance associated with 'nonce' to the owner.
    // This would be done during the lockup period in case of fraud or just
    // because the player spent their whole balance and has no incentive to
    // withdraw the 0 balance on their own.
    // player: the misbehaving player
    // nonce: the nonce of the bad withdrawal
    // amount: the amount they should've sent to the owner
    // r,s,v: the signature
    function forceWithdrawal(
        address player,
        uint nonce,
        uint amount,
        Button move,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) public onlyOwner {

        // Check that the nonce and signature match
        require(accounts[player].nonce == nonce);
        require(checkSignature(player, nonce, amount, move, r, s, v));

        // Does the player have a pending withdrawal? (and therefore this is
        // a forced withdrawal in reponse to fraud)
        uint locked_balance = lockedBalanceOf(player);
        if (locked_balance > 0) {
            // Take the remaining amount from the locked balance
            uint orig_to_owner = toOwnerOf(player);
            if (amount < orig_to_owner) {
                return;
            }
            uint extra_amount = amount.sub(orig_to_owner);

            // If they don't have enough locked, just take all of it
            if (locked_balance < extra_amount) {
                extra_amount = locked_balance;
            }

            // Finally reduce the locked balance and send to owner
            decreaseLockedBalance(player, extra_amount);
            increaseOwnerBalance(extra_amount);
        } else {
            // This is a case where the player didn't withdraw so we're doing
            // it for them. If they don't have enough to cover their
            // obligation, take their full deposit
            uint withdraw_amount = amount;
            uint balance = balanceOf(player);
            if (balance < withdraw_amount) {
                withdraw_amount = balance;
            }
            initiateWithdrawalForPlayer(player, withdraw_amount);
        }

    }

    // Withdraw the owner's Ether
    function ownerWithdraw() public onlyOwner {
        uint amount = ownerBalance;
        ownerBalance = 0;
        owner.transfer(amount);
    }

    /**
    @dev Checks signature against channel params
    */
    function checkSignature(
        address player,
        uint nonce,
        uint amount,
        Button move,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) public view returns (bool) {
        return checkSignatureInternal(player, nonce, amount, move, r, s, v, true) ||
               checkSignatureInternal(player, nonce, amount, move, r, s, v, false);
    }

    /**
    @dev Checks signature against channel params
    */
    function checkSignatureInternal(
        address player,
        uint nonce,
        uint amount,
        Button move,
        bytes32 r,
        bytes32 s,
        uint8 v,
        bool hasPrefix
    ) public view returns (bool) {
        bytes32 h = hashAuthorization(nonce, amount, move);
        if (hasPrefix) {
            bytes memory prefix = "\x19Ethereum Signed Message:\n32";
            h = keccak256(abi.encodePacked(prefix, h));
        }

        address addr = recoverAddress(h, r, s, v);

        // Check whether or not the signature validates
        return (addr == player);
    }

    /**
    @dev Recover address from signature and message
    */
    function recoverAddress(
        bytes32 h,
        bytes32 r,
        bytes32 s,
        uint8 v) public pure returns (address)
    {
        return ecrecover(h, v, r, s);
    }

    /**
    @dev Hashes the channel params for signature verification
    */
    function hashAuthorization(
        uint nonce,
        uint amount,
        Button move) public view returns (bytes32) {
        return keccak256(abi.encodePacked(
            keccak256(abi.encodePacked('address contract', 'uint nonce', 'uint value', 'uint button')),
            keccak256(abi.encodePacked(address(this), nonce, amount, uint(move)))
        ));
    }

    function initiateWithdrawalForPlayer(address player, uint owner_amount) private {
        // Ensure no previous withdrawals are still pending
        require(lockedBalanceOf(player) == 0);

        // Check that they have enough on deposit
        uint total_amount = balanceOf(player);
        require(owner_amount <= total_amount);
        uint player_amount = total_amount.sub(owner_amount);

        // Update balances
        decreaseBalance(player, total_amount);
        increaseLockedBalance(player, player_amount);
        increaseOwnerBalance(owner_amount);

        // Record lock time and the owner amount
        accounts[player].lockedAt = block.number;
        accounts[player].toOwner = owner_amount;
    }

    function incrementNonce(address player) private {
        require(nonceOf(player) != 0);
        accounts[player].nonce = accounts[player].nonce.add(1);
    }

    function increaseOwnerBalance(uint amount) private {
        ownerBalance = ownerBalance.add(amount);
    }

    function decreaseLockedBalance(address player, uint amount) private {
        require(lockedBalanceOf(player) >= amount);
        accounts[player].lockedBalance = accounts[player].lockedBalance.sub(amount);
    }

    function increaseLockedBalance(address player, uint amount) private {
        accounts[player].lockedBalance = accounts[player].lockedBalance.add(amount);
    }

    function decreaseBalance(address player, uint amount) private {
        require(balanceOf(player) >= amount);
        accounts[player].balance = accounts[player].balance.sub(amount);
    }

    function increaseBalance(address player, uint amount) private {
        accounts[player].balance = accounts[player].balance.add(amount);
    }

    function toOwnerOf(address player) public view returns (uint) {
        return accounts[player].toOwner;
    }

    function nonceOf(address player) public view returns (uint) {
        return accounts[player].nonce;
    }

    function totalBalanceOf(address player) public view returns (uint) {
        return balanceOf(player).add(lockedBalanceOf(player));
    }

    function balanceOf(address player) public view returns (uint) {
        return accounts[player].balance;
    }

    function lockedBalanceOf(address player) public view returns (uint) {
        return accounts[player].lockedBalance;
    }

    function lockedAt(address player) public view returns (uint) {
        return accounts[player].lockedAt;
    }

    function isLocked(address player) public view returns (bool) {
        return lockedAt(player) != 0;
    }

    function getOwnerBalance() public view returns (uint) {
        return ownerBalance;
    }

    function minimumPayment() public pure returns (uint) {
        return MIN_PAYMENT;
    }

    function minimumPaymentPlayerName() public pure returns (uint) {
        return MIN_PAYMENT_PLAYER_NAME;
    }

    function minimumPaymentRivalName() public pure returns (uint) {
        return MIN_PAYMENT_RIVAL_NAME;
    }

    function lockupPeriod() public view returns (uint) {
        return lockPeriod;
    }
}
