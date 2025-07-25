const express = require('express');
const { ethers } = require('ethers');
const { Web3 } = require('web3');
const router = express.Router();
const { SuiClient, getFullnodeUrl } = require('@mysten/sui.js/client');
const { Ed25519Keypair } = require('@mysten/sui.js/keypairs/ed25519');
const { TransactionBlock } = require('@mysten/sui.js/transactions');
const { fund_escrow, claim_funds, cancel_swap } = require('../../tests/sui');

// Initialize providers
const ethersProvider = new ethers.JsonRpcProvider(process.env.NODE_URL);
const web3 = new Web3(process.env.NODE_URL);
const suiClient = new SuiClient({ url: getFullnodeUrl('testnet') });

/**
 * @swagger
 * /resolver/orders:
 *   get:
 *     summary: Get Sui balance and epoch for a resolver
 *     tags: [Resolver]
 *     parameters:
 *       - in: query
 *         name: address
 *         schema:
 *           type: string
 *         required: true
 *         description: Resolver's Sui address
 *     responses:
 *       200:
 *         description: Sui balance and epoch
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 message:
 *                   type: string
 *                 suiBalance:
 *                   type: string
 *                 suiEpoch:
 *                   type: number
 */
router.get('/orders', async (req, res) => {
  try {
    const { address } = req.query;
    
    // Example using Sui SDK
    const suiBalance = await suiClient.getBalance({ owner: address });
    const suiEpoch = await suiClient.getLatestSuiSystemState();
    
    res.json({ 
      message: 'Get resolver orders',
      suiBalance: suiBalance.totalBalance,
      suiEpoch: suiEpoch.epoch
    });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

/**
 * @swagger
 * /resolver/execute:
 *   post:
 *     summary: Execute an order through resolver on Sui
 *     tags: [Resolver]
 *     requestBody:
 *       required: true
 *       content:
 *         application/json:
 *           schema:
 *             type: object
 *             required:
 *               - orderId
 *               - action
 *             properties:
 *               orderId:
 *                 type: string
 *                 description: The ID of the Sui order object.
 *               action:
 *                 type: string
 *                 enum: [fund, claim, cancel]
 *                 description: The action to perform on the order.
 *               secret:
 *                 type: string
 *                 description: The secret to reveal for claiming funds (required for 'claim' action).
 *               coinToFund:
 *                 type: string
 *                 description: The object ID of the coin to fund the escrow with (required for 'fund' action).
 *     responses:
 *       200:
 *         description: Order executed successfully on Sui
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 message:
 *                   type: string
 *                 result:
 *                   type: object
 *       400:
 *         description: Invalid request or missing parameters
 *       404:
 *         description: Order not found
 */
router.post('/execute', async (req, res) => {
  try {
    const { orderId, secret, action } = req.body; // Added 'action' to determine the Sui function to call

    if (!orderId || !action) {
      return res.status(400).json({ error: 'Missing required parameters: orderId, action' });
    }

    let result;
    switch (action) {
      case 'fund':
        if (!req.body.coinToFund) {
          return res.status(400).json({ error: 'Missing coinToFund for fund action' });
        }
        result = await fund_escrow(orderId, req.body.coinToFund);
        break;
      case 'claim':
        if (!secret) {
          return res.status(400).json({ error: 'Missing secret for claim action' });
        }
        result = await claim_funds(orderId, secret);
        break;
      case 'cancel':
        result = await cancel_swap(orderId);
        break;
      default:
        return res.status(400).json({ error: 'Invalid action specified' });
    }
    
    res.json({ 
      message: `Order ${action} executed successfully on Sui`,
      result: result
    });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

module.exports = router; 