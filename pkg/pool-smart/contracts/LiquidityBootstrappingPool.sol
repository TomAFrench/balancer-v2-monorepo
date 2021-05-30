// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/ReentrancyGuard.sol";
import "@balancer-labs/v2-solidity-utils/contracts/helpers/WordCodec.sol";
import "@balancer-labs/v2-pool-weighted/contracts/BaseWeightedPool.sol";

/**
 * @dev Weighted Pool with mutable weights, designed to support V2 Liquidity Bootstrapping
 */
contract LiquidityBootstrappingPool is BaseWeightedPool, ReentrancyGuard {
    using FixedPoint for uint256;
    using WordCodec for bytes32;

    // Type declarations

    // Use timestamps instead of blocks (used in V1 ConfigurableRightsPool)
    // Could be miner variation, but should not make much difference,
    // and timestamps are easier to understand / more GUI-friendly
    // End weights are likewise packed as 4 uint64's
    struct GradualUpdateParams {
        uint256 startTime;
        uint256 endTime;
        bytes32 endWeights;
    }

    // State variables

    // Storage for the current ongoing weight change
    // Start weights are in _normalizedWeights
    GradualUpdateParams public gradualUpdateParams;

    // Minimum time over which to compute a gradual weight change (i.e., seconds between timestamps)
    uint256 public immutable minWeightChangeDuration;

    // Setting this to false pauses swapping
    bool public publicSwapEnabled;

    // Override base pool default of 8 tokens
    uint256 private constant _MAX_LBP_TOKENS = 4;

    // For gas optimization, store the 4 weights as uint64's in a single state variable
    // These are the "start weights" during a gradual weight change
    bytes32 private _normalizedWeights;

    // The protocol fees will always be charged using the token associated with the max weight in the pool.
    // Not worth packing - only referenced on join/exits
    uint256 private _maxWeightTokenIndex;

    // Event declarations

    event PublicSwapSet(bool isPublicSwap);
    event GradualUpdateScheduled(uint256 startTime, uint256 endTime);

    // Modifiers

    /**
     * @dev Reverts unless sender is the owner
     */
    modifier onlyOwner() {
        _ensureOwner();
        _;
    }

    constructor(
        IVault vault,
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        uint256[] memory normalizedWeights,
        uint256 swapFeePercentage,
        uint256 pauseWindowDuration,
        uint256 bufferPeriodDuration,
        address owner,
        uint256 minDuration,
        bool initialPublicSwap
    )
        BaseWeightedPool(
            vault,
            name,
            symbol,
            tokens,
            new address[](tokens.length), // LBPs can't have asset managers
            swapFeePercentage,
            pauseWindowDuration,
            bufferPeriodDuration,
            owner
        )
    {
        uint256 numTokens = tokens.length;
        _require(numTokens <= _MAX_LBP_TOKENS, Errors.MAX_TOKENS);

        InputHelpers.ensureInputLengthMatch(numTokens, normalizedWeights.length);

        // Ensure  each normalized weight is above them minimum and find the token index of the maximum weight
        uint256 normalizedSum = 0;
        uint256 maxWeightTokenIndex = 0;
        uint256 maxNormalizedWeight = 0;
        for (uint8 i = 0; i < numTokens; i++) {
            uint256 normalizedWeight = normalizedWeights[i];
            _require(normalizedWeight >= _MIN_WEIGHT, Errors.MIN_WEIGHT);

            _setNormalizedWeight(normalizedWeight, i);

            normalizedSum = normalizedSum.add(normalizedWeight);
            if (normalizedWeight > maxNormalizedWeight) {
                maxWeightTokenIndex = i;
                maxNormalizedWeight = normalizedWeight;
            }
        }
        // Ensure that the normalized weights sum to ONE
        _require(normalizedSum == FixedPoint.ONE, Errors.NORMALIZED_WEIGHT_INVARIANT);

        // Initial value; can change later if weights change
        _maxWeightTokenIndex = maxWeightTokenIndex;

        publicSwapEnabled = initialPublicSwap;
        minWeightChangeDuration = minDuration;
    }

    // External functions

    /**
     * @dev Can pause/unpause trading
     */
    function setPublicSwap(bool publicSwap) external onlyOwner whenNotPaused nonReentrant {
        publicSwapEnabled = publicSwap;

        emit PublicSwapSet(publicSwap);
    }

    /**
     * @dev Schedule a gradual weight change, from the current normalizedWeights in storage, to
     * the given endWeights, over startTime to endTime
     */
    function updateWeightsGradually(
        uint256[] memory endWeights,
        uint256 startTime,
        uint256 endTime
    ) external onlyOwner whenNotPaused nonReentrant {
        // solhint-disable-next-line not-rely-on-time
        uint256 currentTime = block.timestamp;

        _require(currentTime < endTime, Errors.GRADUAL_UPDATE_TIME_TRAVEL);

        // If called while a current weight change is ongoing, set starting point to current weights
        _fixCurrentNormalizedWeights(currentTime);

        if (currentTime > startTime) {
            // This means the weight update should start ASAP
            // Moving the start time up prevents a big jump/discontinuity in the weights
            gradualUpdateParams.startTime = currentTime;
        } else {
            gradualUpdateParams.startTime = startTime;
        }

        // Enforce a minimum time over which to make the changes
        // The also prevents endBlock <= startBlock
        _require(
            endTime.sub(gradualUpdateParams.startTime) >= minWeightChangeDuration,
            Errors.WEIGHT_CHANGE_TIME_BELOW_MIN
        );

        // Must specify normalized weights for all tokens
        uint256 numTokens = _getTotalTokens();
        InputHelpers.ensureInputLengthMatch(numTokens, endWeights.length);

        uint256 sumWeights = 0;

        for (uint8 i = 0; i < numTokens; i++) {
            _require(endWeights[i] >= _MIN_WEIGHT, Errors.MIN_WEIGHT);
            _setEndWeight(endWeights[i], i);

            sumWeights = sumWeights.add(endWeights[i]);
        }

        _require(sumWeights == FixedPoint.ONE, Errors.NORMALIZED_WEIGHT_INVARIANT);

        gradualUpdateParams.endTime = endTime;

        emit GradualUpdateScheduled(startTime, endTime);
    }

    // Public functions

    /**
     * @dev Given that the weight callbacks are all view functions, how do we reset the startTime to 0
     * after an update has passed the end block?
     * This can be called on non-view functions that access weights. It doesn't *have* to be called, but
     * gas will generally be slightly higher if it isn't. It's not called on swaps, since the overhead is
     * likely worse than letting it read the end weights.
     * It's public in case people want to call it externally (e.g., if there won't be any more joins/exits)
     */
    function pokeWeights() public {
        // solhint-disable-next-line not-rely-on-time
        if (gradualUpdateParams.startTime != 0 && block.timestamp >= gradualUpdateParams.endTime) {
            _normalizedWeights = gradualUpdateParams.endWeights;

            gradualUpdateParams.startTime = 0;
        }
    }

    // Internal functions

    /**
     * @dev When finalizing or calling updateWeightsGradually again during an update, set the "fixed" weights
     * in storage to the computed ones at the current timestamp.
     */
    function _fixCurrentNormalizedWeights(uint256 currentTime) internal {
        if (gradualUpdateParams.startTime != 0) {
            uint256[] memory normalizedWeights = _getDynamicWeights(currentTime);
            for (uint8 i = 0; i < _getTotalTokens(); i++) {
                _setNormalizedWeight(normalizedWeights[i], i);
            }

            gradualUpdateParams.startTime = 0;
        }
    }

    /**
     * @dev The intial weights are stored in _normalizedWeights. These "fixed" weights also serve as the
     * "start weights" in a gradual weight change.
     *
     * So, if we are not doing a gradual weight change - or it hasn't started, the weights are just
     * these initial/start weights
     *
     * First figure out the token index (or revert if invalid)
     *
     * If we are past the end of a weight change, the weights are equal to the endWeights (also fixed)
     * If we are in the middle of a weight change, calculate and return the dynamic weights, based on the
     * current timestamp
     */
    function _getNormalizedWeight(IERC20 token) internal view override returns (uint256) {
        uint8 i;

        // prettier-ignore
        if (token == _token0) { i = 0; }
        else if (token == _token1) { i = 1; }
        else if (token == _token2) { i = 2; }
        else if (token == _token3) { i = 3; }
        else {
            _revert(Errors.INVALID_TOKEN);
        }

        // solhint-disable-next-line not-rely-on-time
        uint256 currentTime = block.timestamp;

        if (gradualUpdateParams.startTime == 0 || currentTime <= gradualUpdateParams.startTime) {
            return _normalizedWeights.decodeUint64(i * 64);
        } else if (currentTime >= gradualUpdateParams.endTime) {
            // If we are at or past the end block, use the end weights
            // This is a view function, so cannot reset the gradualUpdateParams here
            return gradualUpdateParams.endWeights.decodeUint64(i * 64);
        }

        // Need the dynamic weight
        uint256 totalPeriod = gradualUpdateParams.endTime.sub(gradualUpdateParams.startTime);
        uint256 secondsElapsed = currentTime.sub(gradualUpdateParams.startTime);

        return _getDynamicWeight(i, totalPeriod, secondsElapsed);
    }

    /**
     * @dev The intial weights are stored in _normalizedWeights. These "fixed" weights also serve as the
     * "start weights" in a gradual weight change.
     *
     * So, if we are not doing a gradual weight change - or it hasn't started, the weights are just
     * these initial/start weights
     *
     * If we are past the end of a weight change, the weights are equal to the endWeights (also fixed)
     * If we are in the middle of a weight change, calculate and return the dynamic weights, based on the
     * current timestamp
     */
    function _getNormalizedWeights() internal view override returns (uint256[] memory) {
        // solhint-disable-next-line not-rely-on-time
        uint256 currentTime = block.timestamp;

        if (gradualUpdateParams.startTime == 0 || currentTime <= gradualUpdateParams.startTime) {
            return _getFixedWeights(_normalizedWeights);
        } else if (currentTime >= gradualUpdateParams.endTime) {
            // If we are at or past the end block, use the end weights
            // This is a view function, so cannot reset the gradualUpdateParams here
            return _getFixedWeights(gradualUpdateParams.endWeights);
        }

        return _getDynamicWeights(currentTime);
    }

    function _getMaxWeightTokenIndex() internal view override returns (uint256) {
        return _maxWeightTokenIndex;
    }

    /**
     * @dev Only the owner can join an LBP pool
     * Since all the callbacks that compute weights are view functions, we can't "reset" the gradual update state
     * during those callbacks. Do that on joins and exits (or if pokeWeights is explicitly called externally)
     */
    function _onJoinPool(
        bytes32,
        address,
        address,
        uint256[] memory balances,
        uint256,
        uint256 protocolSwapFeePercentage,
        bytes memory userData
    )
        internal
        override
        //onlyOwner
        whenNotPaused
        returns (
            uint256,
            uint256[] memory,
            uint256[] memory
        )
    {
        // If a gradual weight update has completed, set the normalized weights in storage and clear startTime
        pokeWeights();
        // Needed for the base class fee calculation
        _setMaxWeightTokenIndex();

        return
            BaseWeightedPool._onJoinPool(0, address(0), address(0), balances, 0, protocolSwapFeePercentage, userData);
    }

    function _onExitPool(
        bytes32,
        address,
        address,
        uint256[] memory balances,
        uint256,
        uint256 protocolSwapFeePercentage,
        bytes memory userData
    )
        internal
        override
        returns (
            uint256,
            uint256[] memory,
            uint256[] memory
        )
    {
        // If a gradual weight update has completed, set the normalized weights in storage and clear startTime
        pokeWeights();
        // Needed for the base class fee calculation
        _setMaxWeightTokenIndex();

        return
            BaseWeightedPool._onExitPool(0, address(0), address(0), balances, 0, protocolSwapFeePercentage, userData);
    }

    function _onSwapGivenIn(
        SwapRequest memory swapRequest,
        uint256 currentBalanceTokenIn,
        uint256 currentBalanceTokenOut
    ) internal view virtual override whenNotPaused returns (uint256) {
        // Swaps are disabled while the contract is paused.
        _require(publicSwapEnabled, Errors.SWAPS_PAUSED);

        return BaseWeightedPool._onSwapGivenIn(swapRequest, currentBalanceTokenIn, currentBalanceTokenOut);
    }

    function _onSwapGivenOut(
        SwapRequest memory swapRequest,
        uint256 currentBalanceTokenIn,
        uint256 currentBalanceTokenOut
    ) internal view virtual override whenNotPaused returns (uint256) {
        // Swaps are disabled while the contract is paused.
        _require(publicSwapEnabled, Errors.SWAPS_PAUSED);

        return BaseWeightedPool._onSwapGivenOut(swapRequest, currentBalanceTokenIn, currentBalanceTokenOut);
    }

    // Private functions

    // For the onlyOnwer modifier
    function _ensureOwner() private view {
        _require(msg.sender == getOwner(), Errors.CALLER_NOT_OWNER);
    }

    // Assumes i is in range
    function _setNormalizedWeight(uint256 weight, uint8 i) private {
        _normalizedWeights = _normalizedWeights.insertUint64(weight, i * 64);
    }

    function _setEndWeight(uint256 weight, uint8 i) private {
        gradualUpdateParams.endWeights = gradualUpdateParams.endWeights.insertUint64(weight, i * 64);
    }

    /**
     * @dev Return the fixed weights from the source (either _normalizedWeights or gradualUpdateParams.endWeights)
     */
    function _getFixedWeights(bytes32 source) private view returns (uint256[] memory) {
        uint256 totalTokens = _getTotalTokens();
        uint256[] memory normalizedWeights = new uint256[](totalTokens);

        // prettier-ignore
        {
            if (totalTokens > 0) { normalizedWeights[0] = source.decodeUint64(0); } else { return normalizedWeights; }
            if (totalTokens > 1) { normalizedWeights[1] = source.decodeUint64(64); } else { return normalizedWeights; }
            if (totalTokens > 2) { normalizedWeights[2] = source.decodeUint64(128); } else { return normalizedWeights; }
            if (totalTokens > 3) { normalizedWeights[3] = source.decodeUint64(192); } else { return normalizedWeights; }
        }

        return normalizedWeights;
    }

    function _getDynamicWeights(uint256 currentTime) private view returns (uint256[] memory) {
        uint256 totalTokens = _getTotalTokens();
        uint256[] memory normalizedWeights = new uint256[](totalTokens);

        // Only calculate this once
        uint256 totalPeriod = gradualUpdateParams.endTime.sub(gradualUpdateParams.startTime);
        uint256 secondsElapsed = currentTime.sub(gradualUpdateParams.startTime);

        // prettier-ignore
        {
            if (totalTokens > 0) { normalizedWeights[0] = _getDynamicWeight(0, totalPeriod, secondsElapsed); }
            else { return normalizedWeights; }
            if (totalTokens > 1) { normalizedWeights[1] = _getDynamicWeight(1, totalPeriod, secondsElapsed); }
            else { return normalizedWeights; }
            if (totalTokens > 2) { normalizedWeights[2] = _getDynamicWeight(2, totalPeriod, secondsElapsed); }
            else { return normalizedWeights; }
            if (totalTokens > 3) { normalizedWeights[3] = _getDynamicWeight(3, totalPeriod, secondsElapsed); }
            else { return normalizedWeights; }
        }

        return normalizedWeights;
    }

    /**
     * @dev If there is no ongoing weight update, just return the normalizedWeights from storage
     * If there's an ongoing weight update, but we're at or past the end block, return the endWeights.
     * If we're in the middle of an update, calculate the current weight by linear interpolation.
     */
    function _getDynamicWeight(
        uint8 tokenIndex,
        uint256 totalPeriod,
        uint256 secondsElapsed
    ) private view returns (uint256) {
        uint256 startWeight = _normalizedWeights.decodeUint64(tokenIndex * 64);
        uint256 endWeight = gradualUpdateParams.endWeights.decodeUint64(tokenIndex * 64);

        // If no change, return fixed value
        if (startWeight == endWeight) {
            return startWeight;
        }

        uint256 totalDelta = endWeight < startWeight ? startWeight.sub(endWeight) : endWeight.sub(startWeight);
        uint256 currentDelta = secondsElapsed.mulDown(totalDelta.divDown(totalPeriod));

        return endWeight < startWeight ? startWeight.sub(currentDelta) : startWeight.add(currentDelta);
    }

    function _setMaxWeightTokenIndex() private {
        uint256[] memory currentWeights = _getNormalizedWeights();

        uint256 maxWeightTokenIndex = 0;
        uint256 maxNormalizedWeight = 0;

        for (uint8 i = 0; i < currentWeights.length; i++) {
            if (currentWeights[i] > maxNormalizedWeight) {
                maxWeightTokenIndex = i;
                maxNormalizedWeight = currentWeights[i];
            }
        }

        _maxWeightTokenIndex = maxWeightTokenIndex;
    }
}
