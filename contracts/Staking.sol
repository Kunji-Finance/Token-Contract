// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract SimpleRewards {
    using SafeERC20 for ERC20;
    using Cast for uint256;

    event Staked(address user, uint256 amount);
    event Unstaked(address user, uint256 amount, uint256 rewardsAmount);
    event RewardsPerTokenUpdated(uint256 accumulated);
    event UserRewardsUpdated(address user, uint256 rewards, uint256 checkpoint);

    struct RewardsPerToken {
        uint128 accumulated;                                        // Accumulated rewards per token for the interval, scaled up by 1e18
        uint128 lastUpdated;                                        // Last time the rewards per token accumulator was updated
    }

    struct UserRewards {
        uint128 accumulated;                                        // Accumulated rewards for the user until the checkpoint
        uint128 checkpoint;                                         // RewardsPerToken the last time the user rewards were updated
    }

    struct UserStake {
        uint256 amount;
        uint256 stakeTS;
    }

    //10 days lock until unstake
    uint256 public immutable lockPeriod;
    uint256 public immutable stakeAmountMin;
    ERC20 public immutable stakingToken;                            // Token to be staked
    uint256 public totalStaked;                                     // Total amount staked
    mapping (address => UserStake) public userStake;                  // Amount staked per user

    ERC20 public immutable rewardsToken;                            // Token used as rewards
    uint256 public immutable rewardsRate;                           // Wei rewarded per second among all token holders
    uint256 public immutable rewardsStart;                          // Start of the rewards program
    uint256 public immutable rewardsEnd;  
    uint256 public immutable totalRewards;                         // End of the rewards program       
    RewardsPerToken public rewardsPerToken;                         // Accumulator to track rewards per token
    mapping (address => UserRewards) public accumulatedRewards;     // Rewards accumulated per user
    
    constructor(ERC20 stakingToken_, ERC20 rewardsToken_, uint256 rewardsStart_, uint256 rewardsEnd_, uint256 totalRewards_, uint256 lockPeriod_,uint256 stakeAmountMin_)
    {
        stakingToken = stakingToken_;
        rewardsToken = rewardsToken_;
        rewardsStart = rewardsStart_;
        rewardsEnd = rewardsEnd_;
        totalRewards = totalRewards_;
        rewardsRate = totalRewards_ / (rewardsEnd_ - rewardsStart_); // The contract will fail to deploy if end <= start, as it should
        rewardsPerToken.lastUpdated = rewardsStart_.u128();
        lockPeriod = lockPeriod_.u128();
        stakeAmountMin = stakeAmountMin_;
    }

    /// @notice Update the rewards per token accumulator according to the rate, the time elapsed since the last update, and the current total staked amount.
    function _calculateRewardsPerToken(RewardsPerToken memory rewardsPerTokenIn) internal view returns(RewardsPerToken memory) {
        RewardsPerToken memory rewardsPerTokenOut = RewardsPerToken(rewardsPerTokenIn.accumulated, rewardsPerTokenIn.lastUpdated);
        uint256 totalStaked_ = totalStaked;

        // No changes if the program hasn't started
        if (block.timestamp < rewardsStart) return rewardsPerTokenOut;

        // Stop accumulating at the end of the rewards interval
        uint256 updateTime = block.timestamp < rewardsEnd ? block.timestamp : rewardsEnd;
        uint256 elapsed = updateTime - rewardsPerTokenIn.lastUpdated;
        
        // No changes if no time has passed
        if (elapsed == 0) return rewardsPerTokenOut;
        rewardsPerTokenOut.lastUpdated = updateTime.u128();
        
        // If there are no stakers we just change the last update time, the rewards for intervals without stakers are not accumulated
        if (totalStaked == 0) return rewardsPerTokenOut;

        // Calculate and update the new value of the accumulator.
        rewardsPerTokenOut.accumulated = (rewardsPerTokenIn.accumulated + 1e18 * elapsed * rewardsRate / totalStaked_).u128(); // The rewards per token are scaled up for precision
        return rewardsPerTokenOut;
    }

    /// @notice Calculate the rewards accumulated by a stake between two checkpoints.
    function _calculateUserRewards(uint256 stake_, uint256 earlierCheckpoint, uint256 latterCheckpoint) internal pure returns (uint256) {
        return stake_ * (latterCheckpoint - earlierCheckpoint) / 1e18; // We must scale down the rewards by the precision factor
    }

    /// @notice Update and return the rewards per token accumulator according to the rate, the time elapsed since the last update, and the current total staked amount.
    function _updateRewardsPerToken() internal returns (RewardsPerToken memory){
        RewardsPerToken memory rewardsPerTokenIn = rewardsPerToken;
        RewardsPerToken memory rewardsPerTokenOut = _calculateRewardsPerToken(rewardsPerTokenIn);

        // We skip the storage changes if already updated in the same block, or if the program has ended and was updated at the end
        if (rewardsPerTokenIn.lastUpdated == rewardsPerTokenOut.lastUpdated) return rewardsPerTokenOut;

        rewardsPerToken = rewardsPerTokenOut;
        emit RewardsPerTokenUpdated(rewardsPerTokenOut.accumulated);

        return rewardsPerTokenOut;
    }

    /// @notice Calculate and store current rewards for an user. Checkpoint the rewardsPerToken value with the user.
    function _updateUserRewards(address user) internal returns (UserRewards memory) {
        RewardsPerToken memory rewardsPerToken_ = _updateRewardsPerToken();
        UserRewards memory userRewards_ = accumulatedRewards[user];
        
        // We skip the storage changes if already updated in the same block
        if (userRewards_.checkpoint == rewardsPerToken_.lastUpdated) return userRewards_;
        
        // Calculate and update the new value user reserves.
        userRewards_.accumulated += _calculateUserRewards(userStake[user].amount, userRewards_.checkpoint, rewardsPerToken_.accumulated).u128();
        userRewards_.checkpoint = rewardsPerToken_.accumulated;

        accumulatedRewards[user] = userRewards_;
        emit UserRewardsUpdated(user, userRewards_.accumulated, userRewards_.checkpoint);

        return userRewards_;
    }

    /// @notice Stake tokens.
    function _stake(address user, uint256 amount) internal
    {
        _updateUserRewards(user);
        totalStaked += amount;
        userStake[user].amount += amount;
        userStake[user].stakeTS = block.timestamp;
        stakingToken.safeTransferFrom(user, address(this), amount);
        emit Staked(user, amount);
    }


    /// @notice Unstake tokens.
    function _unstake(address user) internal
    {
        uint256 rewardsAvailable = _updateUserRewards(msg.sender).accumulated;

        //unstaking logic
        uint256 amount = userStake[user].amount;
        totalStaked -= amount;
        userStake[user].amount = 0;

        //claiming logic
        accumulatedRewards[user].accumulated = 0;

        stakingToken.safeTransfer(user, amount + rewardsAvailable);
        emit Unstaked(user, amount, rewardsAvailable);
    }

    /// @notice Stake tokens.
    function stake(uint256 amount) public virtual
    {
        require(amount > stakeAmountMin, "Stake amount cannot be less than minimum");
        _stake(msg.sender, amount);
    }


    /// @notice Unstake tokens.
    function unstake() public virtual
    {
        require(userStake[msg.sender].stakeTS < block.timestamp - lockPeriod, "Lock period for the stake not ended" );
        require(userStake[msg.sender].amount > 0, "Nothing to unstake" );
        _unstake(msg.sender);
    }

    /// @notice Calculate and return current rewards per token.
    function currentRewardsPerToken() public view returns (uint256) {
        return _calculateRewardsPerToken(rewardsPerToken).accumulated;
    }

    /// @notice Calculate and return current rewards for a user.
    /// @dev This repeats the logic used on transactions, but doesn't update the storage.
    function currentUserRewards(address user) public view returns (uint256) {
        UserRewards memory accumulatedRewards_ = accumulatedRewards[user];
        RewardsPerToken memory rewardsPerToken_ = _calculateRewardsPerToken(rewardsPerToken);
        return accumulatedRewards_.accumulated + _calculateUserRewards(userStake[user].amount, accumulatedRewards_.checkpoint, rewardsPerToken_.accumulated);
    }
}

library Cast {
    function u128(uint256 x) internal pure returns (uint128 y) {
        require(x <= type(uint128).max, "Cast overflow");
        y = uint128(x);
    }
}