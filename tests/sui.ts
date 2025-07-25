
import { getFullnodeUrl, SuiClient } from '@mysten/sui.js/client';
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import { TransactionBlock } from '@mysten/sui.js/transactions';
import * as dotenv from 'dotenv';

dotenv.config();

const SUI_TESTNET_USDC_PACKAGE_ID = '0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29';
const SUI_TESTNET_USDC_MODULE = 'usdc';
const SUI_TESTNET_USDC_COIN_TYPE = `${SUI_TESTNET_USDC_PACKAGE_ID}::${SUI_TESTNET_USDC_MODULE}::USDC`;

// This is a placeholder for the actual package ID of the deployed contract
const SWAP_PACKAGE_ID = process.env.SUI_SWAP_PACKAGE_ID || '0x...'; // TODO: Replace with actual deployed package ID 

const client = new SuiClient({ url: getFullnodeUrl('testnet') });

function getKeypair() {
    const privateKey = process.env.SUI_PRIVATE_KEY;
    if (!privateKey) {
        throw new Error('SUI_PRIVATE_KEY environment variable not set');
    }
    return Ed25519Keypair.fromSecretKey(Buffer.from(privateKey, 'hex'));
}

async function initialize_token() {
    const keypair = getKeypair();
    const tx = new TransactionBlock();
    tx.moveCall({
        target: `${SWAP_PACKAGE_ID}::my_token::init`,
        arguments: [],
    });
    await signAndSubmit(keypair, tx);
}

async function create_order(): Promise<string> {
    const keypair = getKeypair();
    const tx = new TransactionBlock();
    const secret = 'my_secret';
    const secretHash = new TextEncoder().encode(secret);

    const [coin] = tx.splitCoins(tx.gas, [tx.pure(1000)]);

    tx.moveCall({
        target: `${SWAP_PACKAGE_ID}::swap::create_order`,
        arguments: [
            tx.pure(keypair.getPublicKey().toSuiAddress()),
            tx.pure('0x0000000000000000000000000000000000000000000000000000000000000000'),
            tx.pure(1000),
            tx.pure(500),
            coin,
            tx.pure(Array.from(secretHash)),
        ],
        typeArguments: [SUI_TESTNET_USDC_COIN_TYPE],
    });
    const result = await signAndSubmit(keypair, tx);

    // Find the created Order object ID
    const createdObject = result.objectChanges?.find(
        (change) => change.type === 'created' && change.objectType.includes('Order')
    );

    if (!createdObject || !('objectId' in createdObject)) {
        throw new Error('Could not find created Order object ID in transaction response');
    }

    return createdObject.objectId;
}

async function fund_escrow(orderId: string, coinToFund: string) {
    const keypair = getKeypair();
    const tx = new TransactionBlock();

    const [coin] = tx.splitCoins(tx.gas, [tx.object(coinToFund)]);

    tx.moveCall({
        target: `${SWAP_PACKAGE_ID}::swap::fund_escrow`,
        arguments: [
            tx.object(orderId),
            coin,
        ],
        typeArguments: [SUI_TESTNET_USDC_COIN_TYPE],
    });
    await signAndSubmit(keypair, tx);
}

async function claim_funds(orderId: string, secret: string) {
    const keypair = getKeypair();
    const tx = new TransactionBlock();
    const secretBytes = new TextEncoder().encode(secret);

    tx.moveCall({
        target: `${SWAP_PACKAGE_ID}::swap::release_funds`,
        arguments: [
            tx.object(orderId),
            tx.pure(Array.from(secretBytes)),
        ],
        typeArguments: [SUI_TESTNET_USDC_COIN_TYPE],
    });
    await signAndSubmit(keypair, tx);
}

async function cancel_swap(orderId: string) {
    const keypair = getKeypair();
    const tx = new TransactionBlock();

    tx.moveCall({
        target: `${SWAP_PACKAGE_ID}::swap::cancel_swap`,
        arguments: [
            tx.object(orderId),
        ],
        typeArguments: [SUI_TESTNET_USDC_COIN_TYPE],
    });
    await signAndSubmit(keypair, tx);
}

async function signAndSubmit(keypair: Ed25519Keypair, tx: TransactionBlock) {
    const result = await client.signAndExecuteTransactionBlock({ signer: keypair, transactionBlock: tx });
    console.log('Transaction result:', result);
}

(async () => {
    await initialize_token();
    await create_order();
})();

export {
    fund_escrow,
    claim_funds,
    cancel_swap,
    create_order,
    initialize_token,
}
