// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

interface IOrderBook {
    enum OrderType {
        BUY,
        SELL
    }

    struct Order {
        uint256 id;
        address trader;
        OrderType orderType;
        uint256 desiredPrice; // desired token price for trade(Limit order Only)
        uint256 tokenAmount; // token amount to trade.
        uint256 remainTokenAmount; // remaining token amount
        uint256 usdcAmount; // usdc amount to purchase token(Buy order only)
        uint256 remainUsdcAmount; // remaining usdc amount(Buy order only)
        bool isFilled;
        bool isMarketOrder;
        bool isCanceled;
        uint256 validTo;
        uint256 lastTradeTimestamp;
        uint256 createdAt;
    }

    event OrderCanceled(uint256 indexed orderId, uint256 cancleTime);
}
