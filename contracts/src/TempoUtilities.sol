// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {ITIP20Factory} from "tempo-std/interfaces/ITIP20Factory.sol";
import {StdPrecompiles} from "tempo-std/StdPrecompiles.sol";

/// @title TempoUtilities
/// @notice Utility functions for Tempo-specific validation.
library TempoUtilities {
    /// @notice Checks if a given address is a TIP-20 compliant token via the factory precompile.
    function isTIP20(address token) internal view returns (bool) {
        return StdPrecompiles.TIP20_FACTORY.isTIP20(token);
    }
}
