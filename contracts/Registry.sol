pragma solidity ^0.4.23;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";

interface RegistryClone {
    function syncAttributeValue(address _who, bytes32 _attribute, uint256 _value) external;
}

contract Registry {
    struct AttributeData {
        uint256 value;
        bytes32 notes;
        address adminAddr;
        uint256 timestamp;
    }
    
    // never remove any storage variables
    address public owner;
    address public pendingOwner;
    bool initialized;

    // Stores arbitrary attributes for users. An example use case is an ERC20
    // token that requires its users to go through a KYC/AML check - in this case
    // a validator can set an account's "hasPassedKYC/AML" attribute to 1 to indicate
    // that account can use the token. This mapping stores that value (1, in the
    // example) as well as which validator last set the value and at what time,
    // so that e.g. the check can be renewed at appropriate intervals.
    mapping(address => mapping(bytes32 => AttributeData)) attributes;
    // The logic governing who is allowed to set what attributes is abstracted as
    // this accessManager, so that it may be replaced by the owner as needed

    bytes32 constant WRITE_PERMISSION = keccak256("canWriteTo-");
    bytes32 constant IS_BLACKLISTED = "isBlacklisted";
    bytes32 constant IS_DEPOSIT_ADDRESS = "isDepositAddress";
    bytes32 constant IS_REGISTERED_CONTRACT = "isRegisteredContract";
    bytes32 constant HAS_PASSED_KYC_AML = "hasPassedKYC/AML";
    bytes32 constant CAN_BURN = "canBurn";

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event SetAttribute(address indexed who, bytes32 attribute, uint256 value, bytes32 notes, address indexed adminAddr);
    event SetManager(address indexed oldManager, address indexed newManager);

    // Allows a write if either a) the writer is that Registry's owner, or
    // b) the writer is writing to attribute foo and that writer already has
    // the canWriteTo-foo attribute set (in that same Registry)
    function confirmWrite(bytes32 _attribute, address _admin) internal view returns (bool) {
        return (_admin == owner || hasAttribute(_admin, keccak256(WRITE_PERMISSION ^ _attribute)));
    }

    function clone() internal view returns (RegistryClone) {
        return RegistryClone(0x0000000000085d4780B73119b644AE5ecd22b376);
    }

    // Writes are allowed only if the accessManager approves
    function setAttribute(address _who, bytes32 _attribute, uint256 _value, bytes32 _notes) public {
        require(confirmWrite(_attribute, msg.sender));
        attributes[_who][_attribute] = AttributeData(_value, _notes, msg.sender, block.timestamp);
        emit SetAttribute(_who, _attribute, _value, _notes, msg.sender);
        clone().syncAttributeValue(_who, _attribute, _value);
    }

    function setAttributeValue(address _who, bytes32 _attribute, uint256 _value) public {
        require(confirmWrite(_attribute, msg.sender));
        attributes[_who][_attribute] = AttributeData(_value, "", msg.sender, block.timestamp);
        emit SetAttribute(_who, _attribute, _value, "", msg.sender);
        clone().syncAttributeValue(_who, _attribute, _value);
    }

    // Returns true if the uint256 value stored for this attribute is non-zero
    function hasAttribute(address _who, bytes32 _attribute) public view returns (bool) {
        return attributes[_who][_attribute].value != 0;
    }

    function requireCanTransfer(address _from, address _to) public view returns (address, bool) {
        require (attributes[_from][IS_BLACKLISTED].value == 0, "blacklisted");
        uint256 depositAddressValue = attributes[address(uint256(_to) >> 20)][IS_DEPOSIT_ADDRESS].value;
        if (depositAddressValue != 0) {
            _to = address(depositAddressValue);
        }
        require (attributes[_to][IS_BLACKLISTED].value == 0, "blacklisted");
        return (_to, attributes[_to][IS_REGISTERED_CONTRACT].value != 0);
    }

    function requireCanTransferFrom(address _sender, address _from, address _to) public view returns (address, bool) {
        require (attributes[_sender][IS_BLACKLISTED].value == 0, "blacklisted");
        return requireCanTransfer(_from, _to);
    }

    function requireCanMint(address _to) public view returns (address, bool) {
        require (attributes[_to][HAS_PASSED_KYC_AML].value != 0);
        require (attributes[_to][IS_BLACKLISTED].value == 0, "blacklisted");
        uint256 depositAddressValue = attributes[address(uint256(_to) >> 20)][IS_DEPOSIT_ADDRESS].value;
        if (depositAddressValue != 0) {
            _to = address(depositAddressValue);
        }
        return (_to, attributes[_to][IS_REGISTERED_CONTRACT].value != 0);
    }

    function requireCanBurn(address _from) public view {
        require (attributes[_from][CAN_BURN].value != 0);
        require (attributes[_from][IS_BLACKLISTED].value == 0);
    }

    // Returns the exact value of the attribute, as well as its metadata
    function getAttribute(address _who, bytes32 _attribute) public view returns (uint256, bytes32, address, uint256) {
        AttributeData memory data = attributes[_who][_attribute];
        return (data.value, data.notes, data.adminAddr, data.timestamp);
    }

    function getAttributeValue(address _who, bytes32 _attribute) public view returns (uint256) {
        return attributes[_who][_attribute].value;
    }

    function getAttributeAdminAddr(address _who, bytes32 _attribute) public view returns (address) {
        return attributes[_who][_attribute].adminAddr;
    }

    function getAttributeTimestamp(address _who, bytes32 _attribute) public view returns (uint256) {
        return attributes[_who][_attribute].timestamp;
    }

    function reclaimEther(address _to) external onlyOwner {
        _to.transfer(address(this).balance);
    }

    function reclaimToken(ERC20 token, address _to) external onlyOwner {
        uint256 balance = token.balanceOf(this);
        token.transfer(_to, balance);
    }

    function syncAttributes(address[] _addresses, bytes32[] _attributes) external {
        RegistryClone replica = clone();
        for (uint i = 0; i < _attributes.length; i++) {
            address who = _addresses[i];
            bytes32 attribute = _attributes[i];
            replica.syncAttributeValue(who, attribute, attributes[who][attribute].value);
        }
    }

    /**
    * @dev Throws if called by any account other than the owner.
    */
    modifier onlyOwner() {
        require(msg.sender == owner, "only Owner");
        _;
    }

    /**
    * @dev Modifier throws if called by any account other than the pendingOwner.
    */
    modifier onlyPendingOwner() {
        require(msg.sender == pendingOwner);
        _;
    }

    /**
    * @dev Allows the current owner to set the pendingOwner address.
    * @param newOwner The address to transfer ownership to.
    */
    function transferOwnership(address newOwner) public onlyOwner {
        pendingOwner = newOwner;
    }

    /**
    * @dev Allows the pendingOwner address to finalize the transfer.
    */
    function claimOwnership() public onlyPendingOwner {
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
