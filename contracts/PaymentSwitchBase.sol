// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import "./ManagedSecurity.sol"; 
import "./PaymentBook.sol"; 
import "./IMasterSwitch.sol";
import "./utils/CarefulMath.sol"; 
import "hardhat/console.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; 

/**
 * @title PaymentSwitchBase
 * 
 * Takes in funds from marketplace, extracts a fee, and batches the payments for transfer
 * to the appropriate parties, holding the funds in escrow in the meantime. 
 * 
 * @author John R. Kosinski
 * LoadPipe 2024
 * All rights reserved. Unauthorized use prohibited.
 */
contract PaymentSwitchBase is ManagedSecurity, PaymentBook, ReentrancyGuard 
    //TODO: compose PaymentBook instead of inherit
{
    //final approval - amount to pay out to various parties
    mapping(address => uint256) internal toPayOut; 
    
    IMasterSwitch public masterSwitch;
    
    //EVENTS 
    event PaymentPlaced (
        address indexed payer, 
        address indexed receiver, 
        uint256 amount
    );
    event PaymentSent ( 
        address indexed receiver, 
        uint256 amount, 
        bool success
    );
    
    
    //ERRORS 
    error PaymentAmountMismatch(uint256 amount1, uint256 amount2);
    error InvalidOrderId(uint256 orderId);
    error PaymentFailed(address receiver);
    
    
    /**
     * Constructor. 
     * 
     * @param _masterSwitch Address of the master switch contract.
     */
    constructor(IMasterSwitch _masterSwitch) {
        _setSecurityManager(ISecurityManager(_masterSwitch.securityManager())); 
        masterSwitch = _masterSwitch;
    }
    
    /**
     * Nullifies a payment by removing it from records (does not refund it) 
     * 
     * @param receiver Intended receiver of the payment to be removed.
     * @param orderId Identifier of the order for which the payment was placed.
     */
    function removePayment(address receiver, uint256 orderId) external onlyRole(SYSTEM_ROLE) {
        _removePendingPayment(receiver, orderId); 
    }
    
    /**
     * Refunds and removes the identified payment. 
     * 
     * @param receiver Intended receiver of the payment to be refunded.
     * @param orderId Identifier of the order for which the payment was placed.
     */
    function refundPayment(address receiver, uint256 orderId) external onlyRole(REFUNDER_ROLE) {
        _refundPayment(receiver, orderId, 0);
    }
    
    //TODO: comment
    function refundPaymentPartial(address receiver, uint256 orderId, uint256 amount) external onlyRole(REFUNDER_ROLE) {
        _refundPayment(receiver, orderId, amount);
    }
    
    //TODO: comment 
    function approveBatch(address[] calldata receivers) external onlyRole(APPROVER_ROLE) {
        for(uint256 n=0; n<receivers.length; n++) {
            approvePayments(receivers[n]);
        }
    }
    
    //TODO: comment 
    function approvePayments(address receiver) public onlyRole(APPROVER_ROLE) {
        _approvePendingBucket(receiver);
    }
    
    //TODO: replace with processBatch
    function processPayments(address receiver) external onlyRole(DAO_ROLE) {
        uint256 amount = approvedFunds[receiver]; 
        
        //break off fee 
        uint256 fee = 0;
        uint256 feeBps = masterSwitch.feeBps();
        if (feeBps > 0) {
            fee = CarefulMath.div(amount, feeBps);
            if (fee > amount)
                fee = 0;
        }
        uint256 toReceiver = amount - fee; 
        
        //set the amounts to pay out 
        toPayOut[receiver] += toReceiver; 
        toPayOut[masterSwitch.vaultAddress()] += fee; 
        
        //process the payment book 
        _processApprovedBucket(receiver);
    }
    
    /**
     * Causes all due payment to be pushed to the specified receiver. 
     * 
     * @param receiver The receiver of the payments to push. 
     */
    function pushPayment(address receiver) external onlyRole(DAO_ROLE) {
        _sendPayment(payable(receiver)); 
    }
    
    /**
     * Pulls all currently due payments to the caller. 
     */
    function pullPayment() external  {
        //TODO: implement 
    }
    
    /**
     * Gets the specified payment, if it exists
     * 
     * @param receiver The receiver of the payment. 
     * @param orderId Identifier for the order for which the payment was placed. 
     */
    function getPendingPayment(address receiver, uint256 orderId) public view returns (PaymentRecord memory) {
        PaymentRecord memory payment;
        if (_pendingPaymentExists(receiver, orderId)) {
            payment = _getPendingPayment(receiver, orderId);
        }
        return payment;
    }
    
    function _refundPayment(address receiver, uint256 orderId, uint256 amount) internal nonReentrant {
        PaymentRecord storage payment = _getPendingPayment(receiver, orderId); 
        
        //throw if order invalid 
        if (payment.payer == address(0)) {
            revert InvalidOrderId(orderId);
        }
        
        if (payment.amount > 0) {
            
            //if no amount passed in, use the whole payment amount 
            if (amount == 0) 
                amount = payment.amount;
        
            //refund amount can't be greater than the original payment 
            if (amount > payment.amount) {
                amount = payment.amount;
            }

            //place refund amount into bucket for payer
            toPayOut[payment.payer] += amount;
            toPayOut[receiver] -= amount; //TODO: check for overflow
            
            //TODO: decrement payment amount 
            payment.amount -= amount;
            
            //remove payment if amount is now 0
            if (payment.amount == 0) {
                payment.refunded = true;
                _removePendingPayment(receiver, orderId); 
            }
        }
    }
    
    /**
     * Does the actual work of sending a payment (whether pull or push) to the intended
     * recipient. 
     * 
     * @param receiver The address of the recipient of payment. 
     */
    function _sendPayment(address receiver) virtual internal nonReentrant {
        uint256 amount = toPayOut[receiver]; 
    
        //checks: 
        if (amount > 0) {
            
            //effects: zero out the approved funds pot
            toPayOut[receiver] = 0;
            
            //interactions: transfer 
            bool success = _doSendPayment(receiver, amount);
            
            if (!success)
                revert PaymentFailed(receiver);
            //TODO: test failed payment
            
            //emit event 
            emit PaymentSent(receiver, amount, success); //TODO: test
        }
    }
    
    function _doSendPayment(address /*receiver*/, uint256 /*amount*/) internal virtual returns (bool) {
        return true;
    }
    
    function _onPaymentReceived(address seller, PaymentRecord calldata payment) internal virtual {
        
        //add payment to book
        _addPendingPayment(seller, payment.orderId, payment.payer, payment.amount);     
        
        //event 
        emit PaymentPlaced( //TODO: add order id 
            payment.payer, 
            seller, 
            payment.amount
        );
    }
}