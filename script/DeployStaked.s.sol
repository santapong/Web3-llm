// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {StakedBountyEscrow} from "../src/StakedBountyEscrow.sol";

/// Deploy StakedBountyEscrow (v1). Parameters come from the environment (with sensible defaults):
///   RESOLVER, ARBITER, CHALLENGE_PERIOD (seconds), RESOLVER_BOND (wei), CHALLENGE_BOND (wei).
/// Run with:
///   forge script script/DeployStaked.s.sol --rpc-url $SEPOLIA_RPC --broadcast --private-key $PK
contract DeployStaked is Script {
    function run() external {
        address resolver = vm.envOr("RESOLVER", msg.sender);
        address arbiter = vm.envOr("ARBITER", msg.sender);
        uint256 challengePeriod = vm.envOr("CHALLENGE_PERIOD", uint256(3 days));
        uint256 resolverBond = vm.envOr("RESOLVER_BOND", uint256(1 ether));
        uint256 challengeBond = vm.envOr("CHALLENGE_BOND", uint256(0.5 ether));

        vm.startBroadcast();
        StakedBountyEscrow escrow =
            new StakedBountyEscrow(resolver, arbiter, challengePeriod, resolverBond, challengeBond);
        vm.stopBroadcast();

        console.log("StakedBountyEscrow deployed at:", address(escrow));
        console.log("resolver:", resolver);
        console.log("arbiter:", arbiter);
        console.log("challengePeriod:", challengePeriod);
    }
}
