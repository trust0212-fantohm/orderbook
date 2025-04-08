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

    struct RecentOrder {
        uint256 dollars;
        uint256 usdcAmount;
        uint256 tokenAmount;
    }

    event TradeExecuted(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        address indexed buyer,
        address seller,
        uint256 price,
        uint256 tokenAmount
    );

    event OrderReverted(uint256 indexed orderId, address indexed trader);

    event OrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        OrderType orderType,
        uint256 desiredPrice,
        uint256 tokenAmount,
        uint256 timeInForce,
        bool isMarket
    );

    event OrderCancelled(
        uint256 indexed orderId,
        address indexed trader,
        OrderType orderType
    );
}
