// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "hardhat/console.sol";

/*
    Based on CVX Staking contract for https://www.convexfinance.com - https://github.com/convex-eth/platform/blob/main/contracts/contracts/CvxLocker.sol
    Changes:
        - upgrade to solidity 0.8.7
        - remove boosted concept
        - remove staking of locked tokens

     *** Locking mechanism ***

    This locking mechanism is based on epochs. An epoch is defined by the `epochDuration`. When locking our tokens,
    the unlock time for this lock period is set to the start of the current running epoch + `lockDuration`.
    The locked tokens of the current epoch are not eligible for voting. Therefore we need to wait for the next
    epoch until we can vote.
    All tokens locked within the same epoch share the same lock and therefore the same unlock time.


    *** Rewards ***
    todo:...
*/

contract FBeetsLocker is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    struct Epoch {
        uint256 supply; //epoch locked supply
        uint256 startTime; //epoch start date
    }

    IERC20 public immutable lockingToken;

    //rewards
    struct EarnedData {
        address token;
        uint256 amount;
    }

    address[] public rewardTokens;

    struct Reward {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    mapping(address => Reward) public rewardData;

    uint256 public immutable epochDuration;

    // Duration of lock/earned penalty period
    uint256 public immutable lockDuration;

    uint256 public constant denominator = 10000;

    // reward token -> distributor -> is approved to add rewards
    mapping(address => mapping(address => bool)) public rewardDistributors;

    // user -> reward token -> amount
    mapping(address => mapping(address => uint256))
        public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    //supplies and epochs
    uint256 public totalLockedSupply;
    Epoch[] public epochs;

    /*
        We keep the total locked amount and an index to the next unprocessed lock per user.
        All locks previous to this index have been either withdrawn or relocked and can be ignored.
    */

    struct Balances {
        uint256 lockedAmount;
        uint256 nextUnlockIndex;
    }

    mapping(address => Balances) public balances;

    /*
        We keep the amount locked and the unlock time (start epoch + lock duration)
        for each user
    */
    struct LockedBalance {
        uint256 locked;
        uint256 unlockTime;
    }

    mapping(address => LockedBalance[]) public userLocks;

    uint256 public kickRewardPerEpoch = 100;
    uint256 public kickRewardEpochDelay = 4;

    bool public isShutdown = false;

    //erc20-like interface
    string private constant _name = "Vote Locked fBeets Token";
    string private constant _symbol = "vfBeets";
    uint8 private constant _decimals = 18;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        IERC20 _lockingToken,
        uint256 _epochDuration,
        uint256 _lockDuration
    ) {
        lockingToken = _lockingToken;
        epochDuration = _epochDuration;
        lockDuration = _lockDuration;

        epochs.push(
            Epoch({
                supply: 0,
                startTime: (block.timestamp / _epochDuration) * _epochDuration
            })
        );
    }

    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    function name() public pure returns (string memory) {
        return _name;
    }

    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    /* ========== ADMIN CONFIGURATION ========== */

    // Add a new reward token to be distributed to lockers
    function addReward(address _rewardsToken, address _distributor)
        public
        onlyOwner
    {
        require(
            rewardData[_rewardsToken].lastUpdateTime == 0,
            "Reward token already added"
        );
        require(
            _rewardsToken != address(lockingToken),
            "Rewarding the locking token is not allowed"
        );
        rewardTokens.push(_rewardsToken);
        rewardData[_rewardsToken].lastUpdateTime = block.timestamp;
        rewardData[_rewardsToken].periodFinish = block.timestamp;
        rewardDistributors[_rewardsToken][_distributor] = true;
    }

    // Modify approval for an address to call notifyRewardAmount
    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external onlyOwner {
        require(
            rewardData[_rewardsToken].lastUpdateTime > 0,
            "Reward token has not been added"
        );
        rewardDistributors[_rewardsToken][_distributor] = _approved;
    }

    //set kick incentive
    function setKickIncentive(
        uint256 _kickRewardPerEpoch,
        uint256 _kickRewardEpochDelay
    ) external onlyOwner {
        require(_kickRewardPerEpoch <= 500, "over max rate of 5% per epoch");
        require(_kickRewardEpochDelay >= 2, "min delay of 2 epochs required");
        kickRewardPerEpoch = _kickRewardPerEpoch;
        kickRewardEpochDelay = _kickRewardEpochDelay;
    }

    //shutdown the contract. release all locks
    function shutdown() external onlyOwner {
        isShutdown = true;
    }

    /* ========== VIEWS ========== */

    function _rewardPerToken(address _rewardsToken)
        internal
        view
        returns (uint256)
    {
        if (totalLockedSupply == 0) {
            return rewardData[_rewardsToken].rewardPerTokenStored;
        }

        Reward memory reward = rewardData[_rewardsToken];
        uint256 secondsSinceLastApplicableRewardTime = _lastTimeRewardApplicable(
                reward.periodFinish
            ) - reward.lastUpdateTime;
        return
            reward.rewardPerTokenStored +
            (((secondsSinceLastApplicableRewardTime * reward.rewardRate) *
                1e18) / totalLockedSupply);
    }

    function _earned(
        address _user,
        address _rewardsToken,
        uint256 _balance
    ) internal view returns (uint256) {
        return
            (_balance *
                (_rewardPerToken(_rewardsToken) -
                    userRewardPerTokenPaid[_user][_rewardsToken])) /
            1e18 +
            rewards[_user][_rewardsToken];
    }

    function _lastTimeRewardApplicable(uint256 _finishTime)
        internal
        view
        returns (uint256)
    {
        return Math.min(block.timestamp, _finishTime);
    }

    function lastTimeRewardApplicable(address _rewardsToken)
        public
        view
        returns (uint256)
    {
        return
            _lastTimeRewardApplicable(rewardData[_rewardsToken].periodFinish);
    }

    function rewardPerToken(address _rewardsToken)
        external
        view
        returns (uint256)
    {
        return _rewardPerToken(_rewardsToken);
    }


    // Address and claimable amount of all reward tokens for the given account
    function claimableRewards(address _account)
        external
        view
        returns (EarnedData[] memory userRewards)
    {
        userRewards = new EarnedData[](rewardTokens.length);
        uint256 lockedAmount = balances[_account].lockedAmount;
        for (uint256 i = 0; i < userRewards.length; i++) {
            address token = rewardTokens[i];
            userRewards[i].token = token;
            userRewards[i].amount = _earned(_account, token, lockedAmount);
        }
        return userRewards;
    }

    // total token balance of an account, including unlocked but not withdrawn tokens
    function lockedBalanceOf(address _user)
        external
        view
        returns (uint256 amount)
    {
        return balances[_user].lockedAmount;
    }

    // an epoch is always the timestamp on the start of an epoch
    function _currentEpoch() internal view returns (uint256) {
        return (block.timestamp / epochDuration) * epochDuration;
    }

    //balance of an account which only includes properly locked tokens as of the most recent eligible epoch
    function balanceOf(address _user) external view returns (uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];
        Balances storage userBalance = balances[_user];
        uint256 nextUnlockIndex = userBalance.nextUnlockIndex;

        //start with current locked amount
        amount = balances[_user].lockedAmount;

        uint256 locksLength = locks.length;
        //remove old records only (will be better gas-wise than adding up)
        for (uint256 i = nextUnlockIndex; i < locksLength; i++) {
            if (locks[i].unlockTime <= block.timestamp) {
                amount = amount - locks[i].locked;
            } else {
                //stop now as no further checks are needed
                break;
            }
        }

        //also remove amount in the current epoch
        if (
            locksLength > 0 &&
            locks[locksLength - 1].unlockTime - lockDuration == _currentEpoch()
        ) {
            amount = amount - locks[locksLength - 1].locked;
        }

        return amount;
    }

    //balance of an account which only includes properly locked tokens at the given epoch
    function balanceAtEpochOf(uint256 _epoch, address _user)
        external
        view
        returns (uint256 amount)
    {
        LockedBalance[] storage locks = userLocks[_user];

        //get timestamp of given epoch index
        uint256 epochStartTime = epochs[_epoch].startTime;
        //get timestamp of first non-inclusive epoch
        uint256 cutoffEpoch = epochStartTime - lockDuration;

        //traverse inversely to make more current queries more gas efficient
        uint256 currentLockIndex = locks.length;

        if (currentLockIndex == 0) {
            return 0;
        }
        do {
            currentLockIndex--;

            uint256 lockEpoch = locks[currentLockIndex].unlockTime -
                lockDuration;

            if (lockEpoch < epochStartTime) {
                if (lockEpoch > cutoffEpoch) {
                    amount += locks[currentLockIndex].locked;
                } else {
                    //stop now as no further checks matter
                    break;
                }
            }
        } while (currentLockIndex > 0);

        return amount;
    }

    //supply of all properly locked balances at most recent eligible epoch
    function totalSupply() external view returns (uint256 supply) {
        uint256 currentEpoch = _currentEpoch();
        uint256 cutoffEpoch = currentEpoch - lockDuration;
        uint256 epochIndex = epochs.length;

        //do not include current epoch's supply
        if (epochs[epochIndex - 1].startTime == currentEpoch) {
            epochIndex--;
        }
        if (epochIndex == 0) {
            return 0;
        }

        //traverse inversely to make more current queries more gas efficient
        do {
            epochIndex--;
            Epoch storage epoch = epochs[epochIndex];
            if (epoch.startTime <= cutoffEpoch) {
                break;
            }
            supply += epoch.supply;
        } while (epochIndex > 0);

        return supply;
    }

    //supply of all properly locked balances at the given epoch
    function totalSupplyAtEpoch(uint256 _epochIndex)
        external
        view
        returns (uint256 supply)
    {
        // if its the first epoch, no locks can be active
        if (_epochIndex == 0) {
            return 0;
        }
        uint256 epochStart = epochs[_epochIndex].startTime;

        uint256 cutoffEpoch = epochStart - lockDuration;
        //        uint256 currentEpoch = _currentEpoch();
        //
        //        //do not include current epoch's supply
        //        if (epochs[_epochIndex].startTime == currentEpoch) {
        //            _epochIndex--;
        //        }

        uint256 currentIndex = _epochIndex;

        //traverse inversely to make more current queries more gas efficient
        // the provided epoch is not counted since its treated as the 'current' epoch
        do {
            currentIndex--;
            Epoch storage epoch = epochs[currentIndex];
            if (epoch.startTime <= cutoffEpoch) {
                break;
            }
            supply += epochs[currentIndex].supply;
        } while (currentIndex > 0);

        return supply;
    }

    //find an epoch index based on timestamp
    function findEpochId(uint256 _time) external view returns (uint256 epoch) {
        uint256 max = epochs.length - 1;
        uint256 min = 0;

        //convert to start point
        _time = (_time / epochDuration) * epochDuration;

        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) break;

            uint256 mid = (min + max + 1) / 2;
            uint256 midEpochBlock = epochs[mid].startTime;
            if (midEpochBlock == _time) {
                //found
                return mid;
            } else if (midEpochBlock < _time) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    // Information on a user's locked balances
    function lockedBalances(address _user)
        external
        view
        returns (
            uint256 total,
            uint256 unlockable,
            uint256 locked,
            LockedBalance[] memory lockData
        )
    {
        LockedBalance[] storage locks = userLocks[_user];
        Balances storage userBalance = balances[_user];
        uint256 nextUnlockIndex = userBalance.nextUnlockIndex;
        uint256 idx;
        for (uint256 i = nextUnlockIndex; i < locks.length; i++) {
            if (locks[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    lockData = new LockedBalance[](locks.length - i);
                }
                lockData[idx] = locks[i];
                idx++;
                locked += locks[i].locked;
            } else {
                unlockable += locks[i].locked;
            }
        }
        return (userBalance.lockedAmount, unlockable, locked, lockData);
    }

    //number of epochs
    function epochCount() external view returns (uint256) {
        return epochs.length;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function checkpointEpoch() external {
        _checkpointEpoch();
    }

    //insert a new epoch if needed. fill in any gaps
    function _checkpointEpoch() internal {
        uint256 currentEpoch = _currentEpoch();

        //check to add
        //first epoch add in constructor, no need to check 0 length
        if (epochs[epochs.length - 1].startTime < currentEpoch) {
            //fill any epoch gaps
            while (epochs[epochs.length - 1].startTime != currentEpoch) {
                uint256 nextEpochDate = epochs[epochs.length - 1].startTime +
                    epochDuration;
                epochs.push(Epoch({supply: 0, startTime: nextEpochDate}));
            }
        }
    }

    // Locked tokens cannot be withdrawn for lockDuration and are eligible to receive stakingReward rewards
    function lock(address _account, uint256 _amount)
        external
        nonReentrant
        updateReward(_account)
    {
        //pull tokens
        lockingToken.safeTransferFrom(msg.sender, address(this), _amount);

        //lock
        _lock(_account, _amount);
    }

    //lock tokens
    function _lock(address _account, uint256 _amount) internal {
        require(_amount > 0, "Cannot lock 0 tokens");
        require(!isShutdown, "Contract is in shutdown");

        Balances storage userBalance = balances[_account];

        //must try check pointing epoch first
        _checkpointEpoch();

        //add user balances
        userBalance.lockedAmount += _amount;
        //add to total supplies
        totalLockedSupply += _amount;

        //add user lock records or add to current
        uint256 currentEpochStartTime = _currentEpoch();
        uint256 unlockTime = currentEpochStartTime + lockDuration; // lock duration = 16 weeks + current week = 17 weeks

        uint256 idx = userLocks[_account].length;
        // if its the first lock or the last lock has shorter unlock time than this lock
        if (idx == 0 || userLocks[_account][idx - 1].unlockTime < unlockTime) {
            userLocks[_account].push(
                LockedBalance({locked: _amount, unlockTime: unlockTime})
            );
        } else {
            LockedBalance storage userLock = userLocks[_account][idx - 1];
            userLock.locked += _amount;
        }

        //update epoch supply, epoch checkpointed above so safe to add to latest
        Epoch storage currentEpoch = epochs[epochs.length - 1];
        currentEpoch.supply += _amount;

        emit Locked(_account, _amount);
    }

    // Withdraw all currently locked tokens where the unlock time has passed
    function _processExpiredLocks(
        address _account,
        bool _relock,
        address _withdrawTo,
        address _rewardAddress,
        uint256 _checkDelay
    ) internal updateReward(_account) {
        LockedBalance[] storage locks = userLocks[_account];
        Balances storage userBalance = balances[_account];
        uint256 unlockedAmount;
        uint256 totalLocks = locks.length;
        uint256 reward = 0;

        require(totalLocks > 0, "Account has no locks");
        //if time is beyond last lock, can just bundle everything together
        if (
            isShutdown ||
            locks[totalLocks - 1].unlockTime <= block.timestamp - _checkDelay
        ) {
            unlockedAmount = userBalance.lockedAmount;

            //dont delete, just set next index
            userBalance.nextUnlockIndex = totalLocks;

            //check for kick reward
            //this wont have the exact reward rate that you would get if looped through
            //but this section is supposed to be for quick and easy low gas processing of all locks
            //we'll assume that if the reward was good enough someone would have processed at an earlier epoch
            if (_checkDelay > 0) {
                uint256 currentEpoch = ((block.timestamp - _checkDelay) /
                    epochDuration) * epochDuration;

                uint256 overdueEpochCount = (currentEpoch -
                    locks[totalLocks - 1].unlockTime) / epochDuration;

                uint256 rewardRate = Math.min(
                    kickRewardPerEpoch * (overdueEpochCount + 1),
                    denominator
                );

                reward =
                    (locks[totalLocks - 1].locked * rewardRate) /
                    denominator;
            }
        } else {
            // we start on nextUnlockIndex since everything before that has already been processed
            uint256 nextUnlockIndex = userBalance.nextUnlockIndex;
            for (uint256 i = nextUnlockIndex; i < totalLocks; i++) {
                //unlock time must be less or equal to time
                if (locks[i].unlockTime > block.timestamp - _checkDelay) break;

                //add to cumulative amounts
                unlockedAmount += locks[i].locked;

                //check for kick reward
                //each epoch over due increases reward
                if (_checkDelay > 0) {
                    uint256 currentEpoch = ((block.timestamp - _checkDelay) /
                        epochDuration) * epochDuration;

                    uint256 overdueEpochCount = (currentEpoch -
                        locks[i].unlockTime) / epochDuration;

                    uint256 rewardRate = Math.min(
                        kickRewardPerEpoch * (overdueEpochCount + 1),
                        denominator
                    );
                    reward += (locks[i].locked * rewardRate) / denominator;
                }
                //set next unlock index
                nextUnlockIndex++;
            }
            //update next unlock index
            userBalance.nextUnlockIndex = nextUnlockIndex;
        }
        require(unlockedAmount > 0, "No expired locks present");

        //update user balances and total supplies
        userBalance.lockedAmount = userBalance.lockedAmount - unlockedAmount;
        totalLockedSupply -= unlockedAmount;

        emit Withdrawn(_account, unlockedAmount, _relock);

        //send process incentive
        if (reward > 0) {
            //reduce return amount by the kick reward
            unlockedAmount -= reward;

            lockingToken.safeTransfer(_rewardAddress, reward);

            emit KickReward(_rewardAddress, _account, reward);
        }

        //relock or return to user
        if (_relock) {
            _lock(_withdrawTo, unlockedAmount);
        } else {
            // transfer unlocked amount - kick reward (if present)
            lockingToken.safeTransfer(_withdrawTo, unlockedAmount);
        }
    }

    // Withdraw/relock all currently locked tokens where the unlock time has passed
    function processExpiredLocks(bool _relock, address _withdrawTo)
        external
        nonReentrant
    {
        _processExpiredLocks(msg.sender, _relock, _withdrawTo, msg.sender, 0);
    }

    function kickExpiredLocks(address _account) external nonReentrant {
        //allow kick after grace period of 'kickRewardEpochDelay'
        _processExpiredLocks(
            _account,
            false,
            _account,
            msg.sender,
            epochDuration * kickRewardEpochDelay
        );
    }

    // Claim all pending rewards
    function getReward(address _account)
        public
        nonReentrant
        updateReward(_account)
    {
        for (uint256 i; i < rewardTokens.length; i++) {
            address _rewardsToken = rewardTokens[i];
            uint256 reward = rewards[_account][_rewardsToken];
            if (reward > 0) {
                rewards[_account][_rewardsToken] = 0;
                IERC20(_rewardsToken).safeTransfer(_account, reward);

                emit RewardPaid(_account, _rewardsToken, reward);
            }
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function _notifyReward(address _rewardsToken, uint256 _reward) internal {
        Reward storage tokenRewardData = rewardData[_rewardsToken];

        // if there has not been a reward for the duration of an epoch, the reward rate resets
        if (block.timestamp >= tokenRewardData.periodFinish) {
            tokenRewardData.rewardRate = _reward / epochDuration;
        } else {
            // adjust reward rate with additional rewards
            uint256 remaining = tokenRewardData.periodFinish - block.timestamp;

            uint256 leftover = remaining * tokenRewardData.rewardRate;
            tokenRewardData.rewardRate = (_reward + leftover) / epochDuration;
        }

        tokenRewardData.lastUpdateTime = block.timestamp;
        tokenRewardData.periodFinish = block.timestamp + epochDuration;
    }

    function notifyRewardAmount(address _rewardsToken, uint256 _reward)
        external
        updateReward(address(0))
    {
        require(rewardDistributors[_rewardsToken][msg.sender]);
        require(_reward > 0, "No reward");

        _notifyReward(_rewardsToken, _reward);

        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the _reward amount
        IERC20(_rewardsToken).safeTransferFrom(
            msg.sender,
            address(this),
            _reward
        );

        emit RewardAdded(_rewardsToken, _reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount)
        external
        onlyOwner
    {
        require(
            _tokenAddress != address(lockingToken),
            "Cannot withdraw staking token"
        );
        require(
            rewardData[_tokenAddress].lastUpdateTime == 0,
            "Cannot withdraw reward token"
        );
        IERC20(_tokenAddress).safeTransfer(owner(), _tokenAmount);
        emit Recovered(_tokenAddress, _tokenAmount);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address _account) {
        {
            //stack too deep
            Balances storage userBalance = balances[_account];
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                rewardData[token].rewardPerTokenStored = _rewardPerToken(token);
                rewardData[token].lastUpdateTime = _lastTimeRewardApplicable(
                    rewardData[token].periodFinish
                );
                if (_account != address(0)) {
                    rewards[_account][token] = _earned(
                        _account,
                        token,
                        userBalance.lockedAmount
                    );
                    userRewardPerTokenPaid[_account][token] = rewardData[token]
                        .rewardPerTokenStored;
                }
            }
        }
        _;
    }

    /* ========== EVENTS ========== */
    event RewardAdded(address indexed _token, uint256 _reward);
    event Locked(address indexed _user, uint256 _lockedAmount);
    event Withdrawn(address indexed _user, uint256 _amount, bool _relocked);
    event KickReward(
        address indexed _user,
        address indexed _kicked,
        uint256 _reward
    );
    event RewardPaid(
        address indexed _user,
        address indexed _rewardsToken,
        uint256 _reward
    );
    event Recovered(address _token, uint256 _amount);
}
