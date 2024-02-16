// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import "./PaymentSwitchBase.sol";
import "hardhat/console.sol";

//TODO: rename to PaymentSwitchNative
/**
 * @title PaymentSwitch
 * 
 * Takes in funds from marketplace, extracts a fee, and batches the payments for transfer
 * to the appropriate parties, holding the funds in escrow in the meantime. 
 * 
 * @author John R. Kosinski
 * LoadPipe 2024
 * All rights reserved. Unauthorized use prohibited.
 */
contract PaymentSwitch is PaymentSwitchBase
{
    /**
     * Constructor. 
     * 
     * @param masterSwitch Address of the master switch contract.
     */
    //TODO: remove the tokenAddress parameter
    constructor(IMasterSwitch masterSwitch, address tokenAddress) PaymentSwitchBase(masterSwitch) {
    }
    
    /**
     * Accepts a payment from a seller to a buyer. 
     * 
     * @param seller Address to which the majority of the payment (minus fee) is due. 
     * @param payment Encapsulates the payment data. 
     */
    function placePayment(address seller, PaymentRecord calldata payment) external payable onlyRole(SYSTEM_ROLE) {
        //check that the amount is correct
        if (payment.amount != msg.value)
            revert PaymentAmountMismatch(payment.amount, msg.value);
            
        _onPaymentReceived(seller, payment);
    }
    
    function _doSendPayment(address receiver, uint256 amount) internal override returns (bool) {
        (bool success,) = payable(receiver).call{value: amount}("");
        return success;
    }
}