/* global artifacts, contract, it, assert */
/* eslint-disable prefer-reflect */
const {
  BN,
  constants,
  expectEvent,
  expectRevert,
  balance,
  ether,
} = require('@openzeppelin/test-helpers');
const GenArtCollection = artifacts.require('GenArtCollection.sol');
const GenArtInterface = artifacts.require('GenArtInterface.sol');
const GenArtSale = artifacts.require('GenArt.sol');
const GenArtGovToken = artifacts.require('GenArtGovToken.sol');
const GenArtTreasury = artifacts.require('GenArtTreasury.sol');
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

contract('GenArtTreasury', (accounts) => {
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

  it('claim standard member tokens', async () => {
    await genArtTreasury.claimTokensMembership('1', { from: user5 });
    await genArtTreasury.claimTokensMembership('1', { from: user5 });
    const balance = await genArtGovToken.balanceOf.call(user5);
    expect(balance.toString()).equals(
      new BigNumber(4000).times(new BigNumber(10).pow(18)).toString()
    );
  });

  it('claim all membership tokens', async () => {
    await genArtTreasury.claimTokensAllMemberships({ from: user6 });
    const balance = await genArtGovToken.balanceOf.call(user6);
    expect(balance.toString()).equals(
      new BigNumber(4000 + 20000).times(new BigNumber(10).pow(18)).toString()
    );
  });

  it('withdraw owner', async () => {
    const amount = new BigNumber(30)
      .times(new BigNumber(10).pow(24))
      .toString();
    const amount2 = new BigNumber(23)
      .times(new BigNumber(10).pow(24))
      .toString();
    await genArtTreasury.withdraw(amount, user3, { from: owner });
    await genArtTreasury.withdraw(amount2, user3, { from: owner });
    const balance = await genArtGovToken.balanceOf.call(user3);
    expect(balance.toString()).equals(
      new BigNumber(amount).plus(amount2).toString()
    );
  });

  it('claim tokens team member', async () => {
    await new Promise((rs) => setTimeout(rs, 1000));
    await genArtTreasury.claimTokensTeamMember(user1, { from: user1 });
    await new Promise((rs) => setTimeout(rs, 5500));
    await genArtTreasury.claimTokensTeamMember(user1, { from: user1 });
    const balance2 = await genArtGovToken.balanceOf.call(user1);
    expect(balance2.toString()).equals(
      new BigNumber(3750000).times(new BigNumber(10).pow(18)).toString()
    );
  });

  it('claim tokens partner', async () => {
    const now = Date.now();

    const amount = new BigNumber(10000000)
      .times(new BigNumber(10).pow(18))
      .toString();

    await genArtTreasury.addPartner(
      partner,
      (now / 1000).toFixed(),
      (now / 1000 + 5).toFixed(),
      amount,
      { from: owner }
    );
    await new Promise((rs) => setTimeout(rs, 1253));
    await genArtTreasury.claimTokensPartner(partner, { from: partner });
    await new Promise((rs) => setTimeout(rs, 7000));
    await genArtTreasury.claimTokensPartner(partner, { from: partner });
    const balance = await genArtGovToken.balanceOf.call(partner);
    expect(balance.toString()).equals(amount);
  });
});
