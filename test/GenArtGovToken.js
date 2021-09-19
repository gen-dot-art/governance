/* global artifacts, contract, it, assert */
/* eslint-disable prefer-reflect */
const GenArtCollection = artifacts.require('GenArtCollection.sol');
const GenArtInterface = artifacts.require('GenArtInterface.sol');
const GenArtSale = artifacts.require('GenArt.sol');
const GenArtGovToken = artifacts.require('GenArtGovToken.sol');
const GenArtTreasury = artifacts.require('GenArtTreasury.sol');
const { constants, utils, ethers } = require('ethers');
const { ecsign } = require('ethereumjs-util');
const BigNumber = require('bignumber.js');
BigNumber.config({ EXPONENTIAL_AT: 9999 });

let owner;
let user1;
let user2;
let user3;
let zeroAddress = '0x0000000000000000000000000000000000000000';
let genArtCollection;
let genArtMembership;
let genArtGovToken;
let genArtTreasury;

const URI_1 = 'https://localhost:8080/premium/';
const URI_2 = 'https://localhost:8080/gold/';
const URI = 'https://localhost:8080/metadata/';
const SCALE = new BigNumber(10).pow(18);
const NAME = 'TEST';
const SYMBOL = 'SYMB';
const priceStandard = new BigNumber(0.1).times(SCALE);
const priceGold = new BigNumber(0.5).times(SCALE);
let partner;

const DOMAIN_TYPEHASH = utils.keccak256(
  utils.toUtf8Bytes(
    'EIP712Domain(string name,uint256 chainId,address verifyingContract)'
  )
);

const PERMIT_TYPEHASH = utils.keccak256(
  utils.toUtf8Bytes(
    'Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)'
  )
);

contract('GenArtGovToken', (accounts) => {
  before(async () => {
    owner = accounts[0];
    user1 = accounts[1];
    user2 = accounts[2];
    user3 = accounts[3];
    user4 = accounts[4];
    user5 = accounts[5];
    user6 = accounts[6];
    user7 = accounts[7];
    partner = user7;

    genArtMembership = await GenArtSale.new(NAME, SYMBOL, URI_1, URI_2, 10, {
      from: owner,
    });
    await genArtMembership.setPaused(false, {
      from: owner,
    });
    await genArtMembership.mint(user5, {
      from: user5,
      value: priceStandard,
    });
    await genArtMembership.mint(user6, {
      from: user6,
      value: priceStandard,
    });
    await genArtMembership.mintGold(user6, {
      from: user6,
      value: priceGold,
    });

    genArtInterface = await GenArtInterface.new(genArtMembership.address, {
      from: owner,
    });

    genArtCollection = await GenArtCollection.new(
      NAME,
      SYMBOL,
      URI,
      genArtInterface.address,
      {
        from: owner,
      }
    );
    const now = Date.now();
    genArtTreasury = await GenArtTreasury.new(
      genArtInterface.address,
      genArtMembership.address,
      (now / 1000).toFixed(),
      (now / 1000 + 5).toFixed(),
      user1,
      user2,
      user3,
      user4,
      {
        from: owner,
      }
    );

    genArtGovToken = await GenArtGovToken.new(genArtTreasury.address, {
      from: owner,
    });

    await genArtTreasury.updateGenArtTokenAddress(genArtGovToken.address, {
      from: owner,
    });
  });

  after(async () => {});

  it('mint tokens', async () => {
    const balance = await genArtGovToken.balanceOf.call(genArtTreasury.address);
    expect(balance.toString()).equals(
      new BigNumber(100).times(new BigNumber(10).pow(24)).toString()
    );
  });

  it('permit', async () => {
    const chain = (await genArtGovToken.getChainId()).toString();
    console.log('chain', chain);
    const domainSeparator = utils.keccak256(
      utils.defaultAbiCoder.encode(
        ['bytes32', 'bytes32', 'uint256', 'address'],
        [
          DOMAIN_TYPEHASH,
          utils.keccak256(utils.toUtf8Bytes('GEN.ART')),
          chain,
          genArtGovToken.address,
        ]
      )
    );
    const wallet = ethers.Wallet.createRandom();
    const owner = wallet.address;
    const spender = user2;
    const value = 123;
    const deadline = (Date.now() / 1000 + 1000).toFixed();
    const digest = utils.keccak256(
      utils.solidityPack(
        ['bytes1', 'bytes1', 'bytes32', 'bytes32'],
        [
          '0x19',
          '0x01',
          domainSeparator,
          utils.keccak256(
            utils.defaultAbiCoder.encode(
              [
                'bytes32',
                'address',
                'address',
                'uint256',
                'uint256',
                'uint256',
              ],
              [PERMIT_TYPEHASH, owner, spender, value, '0', deadline]
            )
          ),
        ]
      )
    );

    const { v, r, s } = ecsign(
      Buffer.from(digest.slice(2), 'hex'),
      Buffer.from(wallet.privateKey.slice(2), 'hex')
    );

    await genArtGovToken.permit(
      owner,
      spender,
      value,
      deadline,
      v,
      utils.hexlify(r),
      utils.hexlify(s)
    );
    expect((await genArtGovToken.allowance(owner, spender)).toString()).equals(
      value.toString()
    );
    expect((await genArtGovToken.nonces(owner)).toString()).equals('1');

    // await genArtGovToken.connect(spender).transferFrom(owner, spender, value);
  });
});
