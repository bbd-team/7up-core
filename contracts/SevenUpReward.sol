// SPDX-License-Identifier: MIT
pragma solidity >=0.5.16;
import './modules/BaseRewardField.sol';

contract SevenUpReward is BaseRewardField {
    
    address public owner;
    address public stakeToken;
    
    event ProductivityIncreased (address indexed user, uint value);
    event ProductivityDecreased (address indexed user, uint value);
    event Mint(address indexed user, uint amount);
    
    constructor() public {
        owner = msg.sender;
    }
    
    function changeOwner(address _owner) external {
        require(msg.sender == owner, "FORBIDDEN");
        owner = _owner;
    }
    
    function initialize(address _stakeToken, address _shareToken) external {
        require(msg.sender == owner, "FORBIDDEN");
        stakeToken = _stakeToken;
        _setShareToken(_shareToken);
    }
    
    function extract(uint _amount) external {
        require(msg.sender == owner, "FORBIDDEN");
        TransferHelper.safeTransfer(shareToken, msg.sender, _amount);
    }
    
    function stake(uint _amount) external {
        TransferHelper.safeTransferFrom(stakeToken, msg.sender, address(this), _amount);
        _increaseProductivity(msg.sender, _amount);
        emit ProductivityIncreased(msg.sender, _amount);
    }
    
    function withdraw(uint _amount) external {
        _decreaseProductivity(msg.sender, _amount);
        TransferHelper.safeTransfer(stakeToken, msg.sender, _amount);
        emit ProductivityDecreased(msg.sender, _amount);
    }
    
    function queryReward() external view returns (uint){
        return _takeWithAddress(msg.sender);
    }
    
    function mintReward() external {
        uint amount = _mint(msg.sender);
        emit Mint(msg.sender, amount);
    }
}