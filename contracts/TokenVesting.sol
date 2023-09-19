// contracts/TokenVesting.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.21;

// OpenZeppelin dependencies
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title TokenVesting
 */
contract TokenVesting is Ownable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    struct VestingSchedule {
        // cliff time of the vesting start in seconds since the UNIX epoch
        uint256 cliff;
        // start time of the vesting period in seconds since the UNIX epoch
        uint256 start;
        // duration of the vesting period in seconds
        uint256 duration;
        // total amount of tokens to be released at the end of the vesting
        uint256 amountTotal;
        // amount of tokens released
        uint256 released;
        // amount to be released after cliff period
        uint256 cliffAllowance;
    }

    // address of the ERC20 token
    ERC20 private immutable _token;
    // beneficiary of tokens after they are released
    mapping(address => VestingSchedule) public vestingSchedules;

    uint256 private vestingSchedulesTotalAmount;
    
    /**
     * @dev Creates a vesting contract.
     * @param token_ address of the ERC20 token contract
     */
    constructor(address token_) {
        // Check that the token address is not 0x0.
        require(token_ != address(0x0));
        // Set the token address.
        _token = ERC20(token_);
        // createVestingSchedule("0x123",getCurrentTime(),604800,31449600,750000000000000000000000,750000000000000000000000);
        // createVestingSchedule("0x123",getCurrentTime(),604800,31449600,750000000000000000000000,750000000000000000000000);
        // createVestingSchedule("0x123",getCurrentTime(),604800,31449600,750000000000000000000000,750000000000000000000000);
        // createVestingSchedule("0x123",getCurrentTime(),604800,31449600,750000000000000000000000,750000000000000000000000);
        // createVestingSchedule("0x123",getCurrentTime(),604800,31449600,750000000000000000000000,750000000000000000000000);


    }

    /**
     * @dev This function is called for plain Ether transfers, i.e. for every call with empty calldata.
     */
    receive() external payable {}

    /**
     * @dev Fallback function is executed if none of the other functions match the function
     * identifier or no data was provided with the function call.
     */
    fallback() external payable {}

    /**
     * @notice Creates a new vesting schedule for a beneficiary.
     * @param _beneficiary address of the beneficiary to whom vested tokens are transferred
     * @param _start start time of the vesting period
     * @param _cliff duration in seconds of the cliff in which tokens will begin to vest
     * @param _duration duration in seconds of the period in which the tokens will vest
     * @param _amount total amount of tokens to be released at the end of the vesting
     * @param _cliffAmount total amount of tokens to be released at the end cliff period
     */
    function createVestingSchedule(
        address _beneficiary,
        uint256 _start,
        uint256 _cliff,
        uint256 _duration,
        uint256 _amount,
        uint256 _cliffAmount
    ) public onlyOwner {
        require(
            getWithdrawableAmount() >= _amount,
            "TokenVesting: cannot create vesting schedule because not sufficient tokens"
        );
        require(_duration > 0, "TokenVesting: duration must be > 0");
        require(_amount > 0, "TokenVesting: amount must be > 0");
        require(_duration >= _cliff, "TokenVesting: duration must be >= cliff");
        require(vestingSchedules[_beneficiary].start == 0, "TokenVesting:Beneficiary already registered");
        uint256 cliff = _start + _cliff;
        vestingSchedules[_beneficiary] = VestingSchedule(
            cliff,
            _start,
            _duration,
            _amount,
            0,
            _cliffAmount
        );
        vestingSchedulesTotalAmount = vestingSchedulesTotalAmount + _amount;
    }

    /**
     * @notice Withdraw the specified amount if possible.
     * @param amount the amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant onlyOwner {
        require(getWithdrawableAmount() >= amount, "TokenVesting: not enough withdrawable funds");
        SafeERC20.safeTransfer(_token, msg.sender, amount);
    }

    /**
     * @notice Release vested amount of tokens.
     * @param amount the amount to release
     */
    function release(uint256 amount) public nonReentrant {
        VestingSchedule storage vestingSchedule = vestingSchedules[msg.sender];
        require(vestingSchedule.start > 0 , "TokenVesting: Beneficiary not exist");
        
        uint256 vestedAmount = _computeReleasableAmount(vestingSchedule);
        require(
            vestedAmount >= amount,
            "TokenVesting: cannot release tokens, not enough vested tokens"
        );
        vestingSchedule.released = vestingSchedule.released + amount;
        vestingSchedulesTotalAmount = vestingSchedulesTotalAmount - amount;
        SafeERC20.safeTransfer(_token, msg.sender, amount);
    }

    
    /**
     * @dev Returns the address of the ERC20 token managed by the vesting contract.
     */
    function getToken() external view returns (address) {
        return address(_token);
    }

    /**
     * @notice Computes the vested amount of tokens for the given vesting schedule identifier.
     * @return the vested amount
     */
    function computeReleasableAmount(address _beneficiary)
        external
        view
        returns (uint256)
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[_beneficiary];
        return _computeReleasableAmount(vestingSchedule);
    }

    /**
     * @dev Returns the amount of tokens that can be withdrawn by the owner.
     * @return the amount of tokens
     */
    function getWithdrawableAmount() public view returns (uint256) {
        return _token.balanceOf(address(this)) - vestingSchedulesTotalAmount;
    }

    /**
     * @dev Computes the releasable amount of tokens for a vesting schedule.
     * @return the amount of releasable tokens
     */
    function _computeReleasableAmount(
        VestingSchedule memory vestingSchedule
    ) internal view returns (uint256) {
        // Retrieve the current time.
        uint256 currentTime = getCurrentTime();
        // If the current time is before the cliff, no tokens are releasable.
        if ((currentTime < vestingSchedule.cliff)) {
            return 0;
        }
        // If the current time is after the vesting period, all tokens are releasable,
        // minus the amount already released.
        else if (
            currentTime >= vestingSchedule.start + vestingSchedule.duration
        ) {
            return vestingSchedule.amountTotal - vestingSchedule.released;
        }
        // Otherwise, some tokens are releasable.
        else {
            // Compute the number of full vesting periods that have elapsed.
            uint256 timeFromStart = currentTime - vestingSchedule.cliff;
            uint256 durationOfDistribution = vestingSchedule.duration - (vestingSchedule.cliff - vestingSchedule.start);
            //uint256 secondsPerSlice = vestingSchedule.slicePeriodSeconds;
            //uint256 vestedSlicePeriods = timeFromStart / secondsPerSlice;
            //uint256 vestedSeconds = vestedSlicePeriods * secondsPerSlice;
                     
            uint256 vestedAmount = ((vestingSchedule.amountTotal - vestingSchedule.cliffAllowance) *
            timeFromStart) / durationOfDistribution;

            return (vestedAmount + vestingSchedule.cliffAllowance) - vestingSchedule.released;
            
        }
    }

    /**
     * @dev Returns the current time.
     * @return the current timestamp in seconds.
     */
    function getCurrentTime() public view virtual returns (uint256) {
        return block.timestamp;
    }
}