// SPDX-License-Identifier: MIT
pragma solidity >=0.5.16;
import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./modules/Configable.sol";

contract SevenUpMint is Configable {
    using SafeMath for uint;
    
    uint public mintCumulation;
    uint public amountPerBlock;
    uint public lastRewardBlock;
    
    uint public totalLendProductivity;
    uint public totalBorrowProducitivity;
    uint public accAmountPerLend;
    uint public accAmountPerBorrow;
    
    uint public maxSupply = 100000 * 1e18;
    uint public totalBorrowSupply;
    uint public totalLendSupply;
    
    uint public borrowPower = 0;
    
    struct UserInfo {
        uint amount;     // How many tokens the user has provided.
        uint rewardDebt; // Reward debt. 
        uint rewardEarn; // Reward earn and not minted
    }
    
    mapping(address => UserInfo) public lenders;
    mapping(address => UserInfo) public borrowers;
    
    event BorrowPowerChange (uint oldValue, uint newValue);
    event InterestRatePerBlockChanged (uint oldValue, uint newValue);
    event BorrowerProductivityIncreased (address indexed user, uint value);
    event BorrowerProductivityDecreased (address indexed user, uint value);
    event LenderProductivityIncreased (address indexed user, uint value);
    event LenderProductivityDecreased (address indexed user, uint value);
    
    function changeBorrowPower(uint _value) external onlyDeveloper {
        uint old = borrowPower;
        require(_value != old, 'POWER_NO_CHANGE');
        require(_value <= 10000, 'INVALID_POWER_VALUE');
        
        _update();
        borrowPower = _value;
        
        emit BorrowPowerChange(old, _value);
    }
    
    // External function call
    // This function adjust how many token will be produced by each block, eg:
    // changeAmountPerBlock(100)
    // will set the produce rate to 100/block.
    function changeInterestRatePerBlock(uint value) external onlyDeveloper returns (bool) {
        uint old = amountPerBlock;
        require(value != old, 'AMOUNT_PER_BLOCK_NO_CHANGE');

        _update();
        amountPerBlock = value;

        emit InterestRatePerBlockChanged(old, value);
        return true;
    }

    // Update reward variables of the given pool to be up-to-date.
    function _update() internal virtual {
        if (block.number <= lastRewardBlock) {
            return;
        }

        if (totalLendProductivity.add(totalBorrowProducitivity) == 0) {
            lastRewardBlock = block.number;
            return;
        }
        
        uint256 reward = _currentReward();
        
        uint developAmount = reward.mul(IConfig(config).developPercent()).div(10000);
        TransferHelper.safeTransfer(IConfig(config).token(), IConfig(config).wallet(), developAmount);
        reward = reward.sub(developAmount);
        
        uint borrowReward = reward.mul(borrowPower).div(10000);
        uint lendReward = reward.sub(borrowReward);
        totalBorrowSupply = totalBorrowSupply.add(borrowReward);
        totalLendSupply = totalLendSupply.add(lendReward);

        accAmountPerLend = accAmountPerLend.add(lendReward.mul(1e12).div(totalLendProductivity));
        accAmountPerBorrow = accAmountPerBorrow.add(borrowReward.mul(1e12).div(totalBorrowProducitivity));
        lastRewardBlock = block.number;
    }
    
    function _currentReward() internal virtual view returns (uint){
        uint256 multiplier = block.number.sub(lastRewardBlock);
        uint reward = multiplier.mul(amountPerBlock);
        if(totalLendSupply.add(totalBorrowSupply).add(reward) > maxSupply) {
            reward = maxSupply.sub(totalLendSupply).sub(totalBorrowSupply);
        }
        
        return reward;
    }
    
    // Audit borrowers's reward to be up-to-date
    function _auditBorrower(address user) internal {
        UserInfo storage userInfo = borrowers[user];
        if (userInfo.amount > 0) {
            uint pending = userInfo.amount.mul(accAmountPerBorrow).div(1e12).sub(userInfo.rewardDebt);
            userInfo.rewardEarn = userInfo.rewardEarn.add(pending);
            mintCumulation = mintCumulation.add(pending);
            userInfo.rewardDebt = userInfo.amount.mul(accAmountPerBorrow).div(1e12);
        }
    }
    
    // Audit lender's reward to be up-to-date
    function _auditLender(address user) internal {
        UserInfo storage userInfo = lenders[user];
        if (userInfo.amount > 0) {
            uint pending = userInfo.amount.mul(accAmountPerLend).div(1e12).sub(userInfo.rewardDebt);
            userInfo.rewardEarn = userInfo.rewardEarn.add(pending);
            mintCumulation = mintCumulation.add(pending);
            userInfo.rewardDebt = userInfo.amount.mul(accAmountPerLend).div(1e12);
        }
    }

    function increaseBorrowerProductivity(address user, uint value) external onlyPlatform returns (bool) {
        require(value > 0, 'PRODUCTIVITY_VALUE_MUST_BE_GREATER_THAN_ZERO');

        UserInfo storage userInfo = borrowers[user];
        _update();
        _auditBorrower(user);

        totalBorrowProducitivity = totalBorrowProducitivity.add(value);

        userInfo.amount = userInfo.amount.add(value);
        userInfo.rewardDebt = userInfo.amount.mul(accAmountPerBorrow).div(1e12);
        emit BorrowerProductivityIncreased(user, value);
        return true;
    }

    function decreaseBorrowerProductivity(address user, uint value) external onlyPlatform returns (bool) {
        require(value > 0, 'INSUFFICIENT_PRODUCTIVITY');
        
        UserInfo storage userInfo = borrowers[user];
        require(userInfo.amount >= value, "FORBIDDEN");
        _update();
        _auditBorrower(user);
        
        userInfo.amount = userInfo.amount.sub(value);
        userInfo.rewardDebt = userInfo.amount.mul(accAmountPerBorrow).div(1e12);
        totalBorrowProducitivity = totalBorrowProducitivity.sub(value);

        emit BorrowerProductivityDecreased(user, value);
        return true;
    }
    
    function increaseLenderProductivity(address user, uint value) external onlyPlatform returns (bool) {
        require(value > 0, 'PRODUCTIVITY_VALUE_MUST_BE_GREATER_THAN_ZERO');

        UserInfo storage userInfo = lenders[user];
        _update();
        _auditLender(user);

        totalLendProductivity = totalLendProductivity.add(value);

        userInfo.amount = userInfo.amount.add(value);
        userInfo.rewardDebt = userInfo.amount.mul(accAmountPerLend).div(1e12);
        emit LenderProductivityIncreased(user, value);
        return true;
    }

    // External function call 
    // This function will decreases user's productivity by value, and updates the global productivity
    // it will record which block this is happenning and accumulates the area of (productivity * time)
    function decreaseLenderProductivity(address user, uint value) external onlyPlatform returns (bool) {
        require(value > 0, 'INSUFFICIENT_PRODUCTIVITY');
        
        UserInfo storage userInfo = lenders[user];
        require(userInfo.amount >= value, "FORBIDDEN");
        _update();
        _auditLender(user);
        
        userInfo.amount = userInfo.amount.sub(value);
        userInfo.rewardDebt = userInfo.amount.mul(accAmountPerLend).div(1e12);
        totalLendProductivity = totalLendProductivity.sub(value);

        emit LenderProductivityDecreased(user, value);
        return true;
    }
    
    function takeBorrowWithAddress(address user) public view returns (uint) {
        UserInfo storage userInfo = borrowers[user];
        uint _accAmountPerBorrow = accAmountPerBorrow;
        if (block.number > lastRewardBlock && totalBorrowProducitivity != 0) {
            uint reward = _currentReward();
            uint developAmount = reward.mul(IConfig(config).developPercent()).div(10000);
            reward = reward.sub(developAmount);
            uint borrowReward = reward.mul(borrowPower).div(10000);
            
            _accAmountPerBorrow = accAmountPerBorrow.add(borrowReward.mul(1e12).div(totalBorrowProducitivity));
        }
        return userInfo.amount.mul(_accAmountPerBorrow).div(1e12).sub(userInfo.rewardDebt).add(userInfo.rewardEarn);
    }
    
    function takeLendWithAddress(address user) public view returns (uint) {
        UserInfo storage userInfo = lenders[user];
        uint _accAmountPerLend = accAmountPerLend;
        if (block.number > lastRewardBlock && totalLendProductivity != 0) {
            uint reward = _currentReward();
            uint developAmount = reward.mul(IConfig(config).developPercent()).div(10000);
            reward = reward.sub(developAmount);
            
            uint lendReward = reward.sub(reward.mul(borrowPower).div(10000)); 
            _accAmountPerLend = accAmountPerLend.add(lendReward.mul(1e12).div(totalLendProductivity));
        }
        return userInfo.amount.mul(_accAmountPerLend).div(1e12).sub(userInfo.rewardDebt).add(userInfo.rewardEarn);
    }

    // Returns how much a user could earn plus the giving block number.
    function takeBorrowWithBlock() external view returns (uint, uint) {
        uint earn = takeBorrowWithAddress(msg.sender);
        return (earn, block.number);
    }
    
    function takeLendWithBlock() external view returns (uint, uint) {
        uint earn = takeLendWithAddress(msg.sender);
        return (earn, block.number);
    }


    // External function call
    // When user calls this function, it will calculate how many token will mint to user from his productivity * time
    // Also it calculates global token supply from last time the user mint to this time.
    function mintBorrower() external returns (uint) {
        _update();
        _auditBorrower(msg.sender);
        require(borrowers[msg.sender].rewardEarn > 0, "NOTHING TO MINT");
        uint amount = borrowers[msg.sender].rewardEarn;
        TransferHelper.safeTransfer(IConfig(config).token(), msg.sender, borrowers[msg.sender].rewardEarn);
        borrowers[msg.sender].rewardEarn = 0;
        return amount;
    }
    
    function mintLender() external returns (uint) {
        _update();
        _auditLender(msg.sender);
        require(lenders[msg.sender].rewardEarn > 0, "NOTHING TO MINT");
        uint amount = lenders[msg.sender].rewardEarn;
        TransferHelper.safeTransfer(IConfig(config).token(), msg.sender, lenders[msg.sender].rewardEarn);
        lenders[msg.sender].rewardEarn = 0;
        return amount;
    }

    // Returns how many productivity a user has and global has.
    function getBorrowerProductivity(address user) external view returns (uint, uint) {
        return (borrowers[user].amount, totalBorrowProducitivity);
    }
    
    function getLenderProductivity(address user) external view returns (uint, uint) {
        return (lenders[user].amount, totalLendProductivity);
    }

    // Returns the current gorss product rate.
    function interestsPerBlock() external view returns (uint, uint) {
        return (accAmountPerBorrow, accAmountPerLend);
    }
}