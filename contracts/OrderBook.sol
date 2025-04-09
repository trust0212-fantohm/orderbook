// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";

contract OrderBook is
    Initializable,
    IOrderBook,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    uint256[] public fulfilledOrderIds;

    IERC20 public usdc;
    IERC20 public token;

    uint256 private constant BASE_BIPS = 10000;
    uint256 private constant price_decimals = 18;

    uint256 public nonce;
    uint256 public buyFeeBips;
    uint256 public sellFeeBips;

    address public treasury;

    mapping(OrderType => uint256[]) public activeOrderIds; // Tracks active order IDs by type
    mapping(uint256 => Order) public orders; // Maps order ID to Order struct
    mapping(address => uint256[]) public orderIdsByUser; // Tracks order IDs by user

    function initialize(
        address _usdcAddress,
        address _tokenAddress,
        address _treasury
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        usdc = IERC20(_usdcAddress);
        token = IERC20(_tokenAddress);
        treasury = _treasury;
        buyFeeBips = 500;
        sellFeeBips = 500;
        nonce = 0;
    }

    /**
     * @dev Create new buy market order which will be executed instantly
     */
    function createBuyMarketOrder(uint256 usdcAmount) external nonReentrant {
        require(usdcAmount > 0, "No USDC amount");

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        Order memory buyMarketOrder = Order({
            id: nonce,
            trader: msg.sender,
            orderType: OrderType.BUY,
            desiredPrice: 0,
            tokenAmount: 0,
            remainTokenAmount: 0,
            usdcAmount: usdcAmount,
            remainUsdcAmount: usdcAmount,
            isFilled: false,
            isMarketOrder: true,
            isCanceled: false,
            validTo: 0,
            lastTradeTimestamp: 0,
            createdAt: block.timestamp
        });

        orders[nonce] = buyMarketOrder;
        orderIdsByUser[msg.sender].push(nonce);

        require(
            activeOrderIds[OrderType.SELL].length > 0,
            "No active sell orders"
        );

        uint256 totalTokens = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeOrderIds[OrderType.SELL].length;
            i > 0 && buyMarketOrder.remainUsdcAmount > 0;

        ) {
            uint256 currentPrice = orders[activeOrderIds[OrderType.SELL][i - 1]]
                .desiredPrice;
            uint256 j = i;

            while (
                j > 0 &&
                orders[activeOrderIds[OrderType.SELL][j - 1]].desiredPrice ==
                currentPrice
            ) {
                j--;
            }

            uint256 start = j;
            uint256 end = i;

            // Compute total time weight for this price group
            uint256 totalWeight = 0;
            for (uint256 k = start; k < end; k++) {
                Order memory activeSellOrder = orders[
                    activeOrderIds[OrderType.SELL][k]
                ];
                if (!isInvalidOrder(activeSellOrder.id)) {
                    uint256 w = nowTime - activeSellOrder.createdAt;
                    if (w == 0) w = 1;
                    totalWeight += w;
                }
            }

            // Apply time-weighted matching
            (
                uint256 tokenFilled,
                uint256 usdcUsed
            ) = distributeBuyOrderAcrossPriceLevel(
                    buyMarketOrder,
                    currentPrice,
                    start,
                    end,
                    totalWeight,
                    nowTime
                );

            totalTokens += tokenFilled;
            buyMarketOrder.remainUsdcAmount -= usdcUsed;

            i = start; // move to next price level
        }

        if (buyMarketOrder.remainUsdcAmount > 0) {
            // revert("Insufficient Token Supply");
            // If there are still USDC left, refund it back to the trader
            usdc.safeTransfer(
                buyMarketOrder.trader,
                buyMarketOrder.remainUsdcAmount
            );
        }

        fulfilledOrderIds.push(nonce);
        cleanLimitOrders(OrderType.SELL);

        // Transfer Token to Buyer
        (uint256 _realAmount, uint256 _feeAmount) = getAmountDeductFee(
            totalTokens,
            OrderType.BUY
        );
        token.safeTransfer(buyMarketOrder.trader, _realAmount);
        token.safeTransfer(treasury, _feeAmount);

        buyMarketOrder.lastTradeTimestamp = block.timestamp;

        nonce++;
    }

    function distributeBuyOrderAcrossPriceLevel(
        Order memory buyOrder,
        uint256 currentPrice,
        uint256 start,
        uint256 end,
        uint256 totalWeight,
        uint256 nowTime
    ) internal returns (uint256 tokenFilled, uint256 usdcUsed) {
        uint256 remainUsdcAmount = buyOrder.remainUsdcAmount;
        uint256 remainTotalWeight = totalWeight;

        for (uint256 k = start; k < end && remainUsdcAmount > 0; k++) {
            Order storage activeSellOrder = orders[
                activeOrderIds[OrderType.SELL][k]
            ];
            if (isInvalidOrder(activeSellOrder.id)) continue;

            uint256 weight = nowTime - activeSellOrder.createdAt;
            if (weight == 0) weight = 1;

            uint256 usdcShare = (remainUsdcAmount * weight) / remainTotalWeight;
            uint256 tokenQty = (usdcShare * 10 ** price_decimals) /
                currentPrice;

            if (tokenQty > activeSellOrder.remainTokenAmount) {
                tokenQty = activeSellOrder.remainTokenAmount;
                usdcShare = (tokenQty * currentPrice) / 10 ** price_decimals;
            }

            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                usdcShare,
                OrderType.SELL
            );
            usdc.safeTransfer(activeSellOrder.trader, realAmount);
            usdc.safeTransfer(treasury, feeAmount);

            activeSellOrder.remainTokenAmount -= tokenQty;
            activeSellOrder.lastTradeTimestamp = block.timestamp;

            if (activeSellOrder.remainTokenAmount == 0) {
                activeSellOrder.isFilled = true;
            }

            tokenFilled += tokenQty;
            usdcUsed += usdcShare;
            remainTotalWeight -= weight;
            remainUsdcAmount -= usdcShare;
        }
    }

    /**
     * @dev Create new sell market order which will be executed instantly
     */
    function createSellMarketOrder(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "No Token Amount");

        token.safeTransferFrom(msg.sender, address(this), tokenAmount);

        Order memory sellMarketOrder = Order({
            id: nonce,
            trader: msg.sender,
            orderType: OrderType.SELL,
            desiredPrice: 0,
            tokenAmount: tokenAmount,
            remainTokenAmount: tokenAmount,
            usdcAmount: 0,
            remainUsdcAmount: 0,
            isFilled: false,
            isMarketOrder: true,
            isCanceled: false,
            validTo: 0,
            lastTradeTimestamp: 0,
            createdAt: block.timestamp
        });

        orders[nonce] = sellMarketOrder;
        orderIdsByUser[msg.sender].push(nonce);

        require(
            activeOrderIds[OrderType.BUY].length > 0,
            "No active buy orders"
        );

        uint256 totalUsdc = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeOrderIds[OrderType.BUY].length;
            i > 0 && sellMarketOrder.remainTokenAmount > 0;

        ) {
            uint256 currentPrice = orders[activeOrderIds[OrderType.BUY][i - 1]]
                .desiredPrice;
            uint256 j = i;

            while (
                j > 0 &&
                orders[activeOrderIds[OrderType.BUY][j - 1]].desiredPrice ==
                currentPrice
            ) {
                j--;
            }

            uint256 start = j;
            uint256 end = i;

            // Compute total time weight for this price group
            uint256 totalWeight = 0;
            for (uint256 k = start; k < end; k++) {
                Order memory activeBuyOrder = orders[
                    activeOrderIds[OrderType.BUY][k]
                ];
                if (!isInvalidOrder(activeBuyOrder.id)) {
                    uint256 w = nowTime - activeBuyOrder.createdAt;
                    if (w == 0) w = 1;
                    totalWeight += w;
                }
            }

            // Apply time-weighted matching
            (
                uint256 usdcFilled,
                uint256 tokenAmountUsed
            ) = distributeSellOrderAcrossPriceLevel(
                    sellMarketOrder,
                    currentPrice,
                    start,
                    end,
                    totalWeight,
                    nowTime
                );

            totalUsdc += usdcFilled;
            sellMarketOrder.remainTokenAmount -= tokenAmountUsed;

            i = start; // move to next price level
        }

        if (sellMarketOrder.remainTokenAmount > 0) {
            // revert("Insufficient USDC supply");

            // If there are still Token left, refund it back to the trader
            token.safeTransfer(
                sellMarketOrder.trader,
                sellMarketOrder.remainTokenAmount
            );
        }

        fulfilledOrderIds.push(nonce);
        cleanLimitOrders(OrderType.BUY);

        // Transfer USDC to seller
        (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
            totalUsdc,
            OrderType.SELL
        );
        usdc.safeTransfer(sellMarketOrder.trader, realAmount);
        usdc.safeTransfer(treasury, feeAmount);

        sellMarketOrder.lastTradeTimestamp = block.timestamp;

        nonce++;
    }

    function distributeSellOrderAcrossPriceLevel(
        Order memory sellOrder,
        uint256 currentPrice,
        uint256 start,
        uint256 end,
        uint256 totalWeight,
        uint256 nowTime
    ) internal returns (uint256 usdcFilled, uint256 tokenAmountUsed) {
        uint256 remainTokenAmount = sellOrder.remainTokenAmount;
        uint256 remainTotalWeight = totalWeight;

        for (uint256 k = start; k < end && remainTokenAmount > 0; k++) {
            Order storage activeBuyOrder = orders[
                activeOrderIds[OrderType.BUY][k]
            ];
            if (isInvalidOrder(activeBuyOrder.id)) continue;

            uint256 weight = nowTime - activeBuyOrder.createdAt;
            if (weight == 0) weight = 1;

            uint256 share = (remainTokenAmount * weight) / remainTotalWeight;
            if (share > activeBuyOrder.remainTokenAmount) {
                share = activeBuyOrder.remainTokenAmount;
            }

            uint256 usdcAmount = (share * currentPrice) / 10 ** price_decimals;
            if (usdcAmount > activeBuyOrder.remainUsdcAmount) {
                usdcAmount = activeBuyOrder.remainUsdcAmount;
                share = (usdcAmount * 10 ** price_decimals) / currentPrice;
            }

            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                share,
                OrderType.BUY
            );
            token.safeTransfer(activeBuyOrder.trader, realAmount);
            token.safeTransfer(treasury, feeAmount);

            activeBuyOrder.remainUsdcAmount -= usdcAmount;
            activeBuyOrder.lastTradeTimestamp = block.timestamp;

            if (activeBuyOrder.remainTokenAmount == 0) {
                activeBuyOrder.isFilled = true;
            }

            usdcFilled += usdcAmount;
            tokenAmountUsed += share;
            remainTotalWeight -= weight;
            remainTokenAmount -= share;
        }
    }

    /**
     * @dev Create new limit order
     */
    function createLimitOrder(
        uint256 usdcAmount, // For Buy
        uint256 desiredPrice,
        uint256 tokenAmount, // For Sell
        uint256 validTo,
        OrderType orderType
    ) external nonReentrant {
        Order memory newOrder;

        require(validTo > block.timestamp, "Invalid time limit");

        if (orderType == OrderType.BUY) {
            // uint256 usdcAmount = (desiredPrice * tokenAmount) /
            //     10 ** price_decimals;
            usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
            newOrder = Order({
                id: nonce,
                trader: msg.sender,
                orderType: OrderType.BUY,
                desiredPrice: desiredPrice,
                tokenAmount: 0,
                remainTokenAmount: 0,
                usdcAmount: usdcAmount,
                remainUsdcAmount: usdcAmount,
                isFilled: false,
                isMarketOrder: false,
                isCanceled: false,
                validTo: validTo,
                lastTradeTimestamp: 0,
                createdAt: block.timestamp
            });
        } else {
            token.safeTransferFrom(msg.sender, address(this), tokenAmount);
            newOrder = Order({
                id: nonce,
                trader: msg.sender,
                orderType: OrderType.SELL,
                desiredPrice: desiredPrice,
                tokenAmount: tokenAmount,
                remainTokenAmount: tokenAmount,
                usdcAmount: 0,
                remainUsdcAmount: 0,
                isFilled: false,
                isMarketOrder: false,
                isCanceled: false,
                validTo: validTo,
                lastTradeTimestamp: 0,
                createdAt: block.timestamp
            });
        }

        orders[nonce] = newOrder;
        orderIdsByUser[msg.sender].push(nonce);

        uint256 nowTime = block.timestamp;

        // Try to match with opposite orders at the same or better price
        if (orderType == OrderType.BUY) {
            // match with lowest priced sells ≤ desiredPrice
            for (
                uint256 i = activeOrderIds[OrderType.SELL].length;
                i > 0 && newOrder.remainUsdcAmount > 0;

            ) {
                uint256 currentOrderId = activeOrderIds[OrderType.SELL][i - 1];
                Order storage sellOrder = orders[currentOrderId];
                if (
                    isInvalidOrder(sellOrder.id) ||
                    sellOrder.desiredPrice > newOrder.desiredPrice
                ) {
                    i--;
                    continue;
                }

                // Find price group
                uint256 currentPrice = sellOrder.desiredPrice;
                uint256 j = i;
                while (
                    j > 0 &&
                    orders[activeOrderIds[OrderType.SELL][j - 1]]
                        .desiredPrice ==
                    currentPrice
                ) {
                    j--;
                }

                // Weight calc
                uint256 totalWeight = 0;
                for (uint256 k = j; k < i; k++) {
                    Order memory o = orders[activeOrderIds[OrderType.SELL][k]];
                    if (!isInvalidOrder(o.id)) {
                        uint256 w = nowTime - o.createdAt;
                        if (w == 0) w = 1;
                        totalWeight += w;
                    }
                }

                // Time-weighted distribution
                (uint256 tokenFilled, uint256 usdcUsed) = distributeBuyOrderAcrossPriceLevel(
                    newOrder,
                    currentPrice,
                    j,
                    i,
                    totalWeight,
                    nowTime
                );

                // Apply fees for the matched tokens
                (uint256 realTokenAmount, uint256 feeTokenAmount) = getAmountDeductFee(
                    tokenFilled,
                    OrderType.BUY
                );
                token.safeTransfer(newOrder.trader, realTokenAmount);
                token.safeTransfer(treasury, feeTokenAmount);

                newOrder.remainUsdcAmount -= usdcUsed;

                i = j;
            }

            // If partially filled, insert the rest
            if (newOrder.remainUsdcAmount > 0) {
                insertLimitOrder(newOrder.id);
            } else {
                newOrder.isFilled = true;
                orders[nonce] = newOrder;
                fulfilledOrderIds.push(nonce);
            }
        } else {
            // SELL order — match with highest priced buys ≥ desiredPrice
            for (
                uint256 i = activeOrderIds[OrderType.BUY].length;
                i > 0 && newOrder.remainTokenAmount > 0;

            ) {
                uint256 currentOrderId = activeOrderIds[OrderType.BUY][i - 1];
                Order storage buyOrder = orders[currentOrderId];
                if (
                    isInvalidOrder(buyOrder.id) ||
                    buyOrder.desiredPrice < desiredPrice
                ) {
                    i--;
                    continue;
                }

                uint256 currentPrice = buyOrder.desiredPrice;
                uint256 j = i;
                while (
                    j > 0 &&
                    orders[activeOrderIds[OrderType.BUY][j - 1]].desiredPrice ==
                    currentPrice
                ) {
                    j--;
                }

                uint256 totalWeight = 0;
                for (uint256 k = j; k < i; k++) {
                    Order memory o = orders[activeOrderIds[OrderType.BUY][k]];
                    if (!isInvalidOrder(o.id)) {
                        uint256 w = nowTime - o.createdAt;
                        if (w == 0) w = 1;
                        totalWeight += w;
                    }
                }

                // Time-weighted distribution
                (
                    uint256 usdcFilled,
                    uint256 tokenAmountUsed
                ) = distributeSellOrderAcrossPriceLevel(
                        newOrder,
                        currentPrice,
                        j,
                        i,
                        totalWeight,
                        nowTime
                    );

                // Apply fees for the matched USDC
                (uint256 realUsdcAmount, uint256 feeUsdcAmount) = getAmountDeductFee(
                    usdcFilled,
                    OrderType.SELL
                );
                usdc.safeTransfer(newOrder.trader, realUsdcAmount);
                usdc.safeTransfer(treasury, feeUsdcAmount);

                newOrder.remainTokenAmount -= tokenAmountUsed;

                i = j;
            }

            // If partially filled, insert the rest
            if (newOrder.remainTokenAmount > 0) {
                insertLimitOrder(newOrder.id);
            } else {
                newOrder.isFilled = true;
                orders[nonce] = newOrder;
                fulfilledOrderIds.push(nonce);
            }
        }

        cleanLimitOrders(OrderType.BUY);
        cleanLimitOrders(OrderType.SELL);

        nonce++;
    }

    function insertLimitOrder(uint256 orderId) internal {
        Order storage order = orders[orderId]; // Fetch order from storage

        uint256[] storage orderIds = activeOrderIds[order.orderType];

        // Initialize array if empty
        if (orderIds.length == 0) {
            orderIds.push(orderId);
            return;
        }

        // Find the correct position to insert
        uint256 insertPosition = orderIds.length;
        
        if (order.orderType == OrderType.BUY) {
            // Sort orders in ascending order (lower price first)
            for (uint256 i = 0; i < orderIds.length; i++) {
                if (orders[orderIds[i]].desiredPrice > order.desiredPrice) {
                    insertPosition = i;
                    break;
                }
            }
        } else {
            // Sort orders in descending order (higher price first)
            for (uint256 i = 0; i < orderIds.length; i++) {
                if (orders[orderIds[i]].desiredPrice < order.desiredPrice) {
                    insertPosition = i;
                    break;
                }
            }
        }

        // Insert at the found position
        if (insertPosition == orderIds.length) {
            orderIds.push(orderId);
        } else {
            // Shift elements to make room
            orderIds.push(orderIds[orderIds.length - 1]);
            for (uint256 i = orderIds.length - 1; i > insertPosition; i--) {
                orderIds[i] = orderIds[i - 1];
            }
            orderIds[insertPosition] = orderId;
        }
    }

    function cleanLimitOrders(OrderType orderType) internal {
        while (
            activeOrderIds[orderType].length > 0 &&
            isInvalidOrder(
                orders[
                    activeOrderIds[orderType][
                        activeOrderIds[orderType].length - 1
                    ]
                ].id
            )
        ) {
            uint256 lastOrderId = activeOrderIds[orderType][activeOrderIds[orderType].length - 1];
            activeOrderIds[orderType].pop();
            fulfilledOrderIds.push(lastOrderId);
        }
    }

    function isInvalidOrder(uint256 orderId) internal view returns (bool) {
        Order memory order = orders[orderId]; // Fetch order from storage
        return
            order.isCanceled ||
            order.isFilled ||
            order.validTo < block.timestamp ||
            order.remainTokenAmount == 0;
    }

    function getLatestRate()
        external
        view
        returns (Order memory lastBuyOrder, Order memory lastSellOrder)
    {
        // Initialize empty orders
        lastBuyOrder = Order({
            id: 0,
            trader: address(0),
            orderType: OrderType.BUY,
            desiredPrice: 0,
            tokenAmount: 0,
            remainTokenAmount: 0,
            usdcAmount: 0,
            remainUsdcAmount: 0,
            isFilled: false,
            isMarketOrder: false,
            isCanceled: false,
            validTo: 0,
            lastTradeTimestamp: 0,
            createdAt: 0
        });
        
        lastSellOrder = Order({
            id: 0,
            trader: address(0),
            orderType: OrderType.SELL,
            desiredPrice: 0,
            tokenAmount: 0,
            remainTokenAmount: 0,
            usdcAmount: 0,
            remainUsdcAmount: 0,
            isFilled: false,
            isMarketOrder: false,
            isCanceled: false,
            validTo: 0,
            lastTradeTimestamp: 0,
            createdAt: 0
        });

        if (activeOrderIds[OrderType.BUY].length > 0) {
            lastBuyOrder = orders[
                activeOrderIds[OrderType.BUY][
                    activeOrderIds[OrderType.BUY].length - 1
                ]
            ];
        }

        if (activeOrderIds[OrderType.SELL].length > 0) {
            lastSellOrder = orders[
                activeOrderIds[OrderType.SELL][
                    activeOrderIds[OrderType.SELL].length - 1
                ]
            ];
        }
    }

    function getOrderBook(
        uint256 depth,
        OrderType orderType
    ) external view returns (Order[] memory) {
        uint256[] storage activeIds = activeOrderIds[orderType];
        uint256 actualDepth = depth > activeIds.length ? activeIds.length : depth;
        
        Order[] memory result = new Order[](actualDepth);
        
        for (uint256 i = 0; i < actualDepth; i++) {
            result[i] = orders[activeIds[activeIds.length - 1 - i]];
        }
        
        return result;
    }

    modifier onlyOrderMaker(uint256 orderId) {
        require(orderId < nonce, "Invalid order id");
        Order memory order = orders[orderId];
        require(
            order.trader == msg.sender,
            "You are not an maker of this order"
        );
        _;
    }

    function cancelOrder(uint256 orderId) external onlyOrderMaker(orderId) {
        Order storage order = orders[orderId];

        require(!order.isCanceled, "Already canceled");
        require(!order.isFilled, "Order already filled");

        order.isCanceled = true;

        if (order.orderType == OrderType.BUY) {
            usdc.safeTransfer(order.trader, order.remainUsdcAmount);
        } else {
            token.safeTransfer(order.trader, order.remainTokenAmount);
        }

        emit OrderCanceled(order.id, block.timestamp);
    }

    function setbuyFeeBips(uint256 _buyFeeBips) external onlyOwner {
        require(buyFeeBips != _buyFeeBips, "Same buyFeeBips");
        require(_buyFeeBips < BASE_BIPS, "Invalid buyFeeBips");
        buyFeeBips = _buyFeeBips;
    }

    function setsellFeeBips(uint256 _sellFeeBips) external onlyOwner {
        require(sellFeeBips != _sellFeeBips, "Invalid sellFeeBips");
        require(_sellFeeBips < BASE_BIPS, "Invalid sellFeeBips");
        sellFeeBips = _sellFeeBips;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;
    }

    function getAmountDeductFee(
        uint256 amount,
        OrderType orderType
    ) internal view returns (uint256 realAmount, uint256 feeAmount) {
        uint256 feeBips = orderType == OrderType.BUY ? buyFeeBips : sellFeeBips;

        realAmount = (amount * (BASE_BIPS - feeBips)) / BASE_BIPS;
        feeAmount = amount - realAmount;
    }
}
