// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IOracle} from "./interfaces/IOracle.sol";

contract OrderBook is
    Initializable,
    IOrderBook,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256[] public fulfilledOrderIds;

    IERC20Upgradeable public usdc;
    IERC20Upgradeable public token;
    IOracle public priceOracle; // token-usdc price oracle

    uint256 private constant BASE_BIPS = 10000;
    uint256 private constant price_decimals = 18;

    uint256 public nonce;
    uint256 public buyFeeBips;
    uint256 public sellFeeBips;
    
    address public treasury;

    mapping(uint256 => Order) public orders; // Maps order ID to Order struct
    mapping(address => uint256[]) private ordersByUser; // Tracks order IDs by user
    mapping(OrderType => uint256[]) public activeOrderIds; // Tracks active order IDs by type

    function initialize(
        address _usdcAddress,
        address _tokenAddress,
        address _priceOracle,
        address _treasury
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        usdc = IERC20Upgradeable(_usdcAddress);
        token = IERC20Upgradeable(_tokenAddress);
        priceOracle = IOracle(_priceOracle);
        treasury = _treasury;
        buyFeeBips = 500;
        sellFeeBips = 500;
        nonce = 0;
    }

    /**
     * @dev Create new buy market order which will be executed instantly
     */
    function createBuyMarketOrder(uint256 usdcAmount) external nonReentrant {
        require(usdcAmount > 0, "Insufficient USDC amount");

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        Order memory marketOrder = Order(
            nonce,
            msg.sender,
            OrderType.BUY,
            0,
            0,
            0,
            usdcAmount,
            usdcAmount,
            false,
            true,
            false,
            0,
            0,
            block.timestamp
        );

        nonce++;

        require(activeOrderIds[OrderType.SELL].length > 0, "No active sell orders");

        uint256 totalTokens = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeOrderIds[OrderType.SELL].length;
            i > 0 && marketOrder.remainUsdcAmount > 0;

        ) {
            uint256 currentPrice = orders[activeOrderIds[OrderType.SELL][i - 1]].desiredPrice;
            uint256 j = i;

            while (
                j > 0 && orders[activeOrderIds[OrderType.SELL][j - 1]].desiredPrice == currentPrice
            ) {
                j--;
            }

            uint256 start = j;
            uint256 end = i;

            // Compute total time weight for this price group
            uint256 totalWeight = 0;
            for (uint256 k = start; k < end; k++) {
                Order memory o = orders[activeOrderIds[OrderType.SELL][k]];
                if (!isInvalidOrder(o)) {
                    uint256 w = nowTime - o.createdAt;
                    if (w == 0) w = 1;
                    totalWeight += w;
                }
            }

            // Apply time-weighted matching
            (
                uint256 tokenFilled,
                uint256 usdcUsed
            ) = distributeBuyOrderAcrossPriceLevel(
                    marketOrder,
                    currentPrice,
                    start,
                    end,
                    totalWeight,
                    nowTime
                );

            totalTokens += tokenFilled;
            marketOrder.remainUsdcAmount -= usdcUsed;

            i = start; // move to next price level
        }

        if (marketOrder.remainUsdcAmount > 0) {
            revert("Insufficient Token Supply");
        }

        orders[nonce] = marketOrder;
        fulfilledOrderIds.push(nonce);
        ordersByUser[msg.sender].push(nonce);
        cleanLimitOrders();

        (uint256 _realAmount, uint256 _feeAmount) = getAmountDeductFee(
            totalTokens,
            OrderType.BUY
        );
        token.safeTransfer(msg.sender, _realAmount);
        token.safeTransfer(treasury, _feeAmount);
    }

    function distributeBuyOrderAcrossPriceLevel(
        Order memory marketOrderMem,
        uint256 currentPrice,
        uint256 start,
        uint256 end,
        uint256 totalWeight,
        uint256 nowTime
    ) internal returns (uint256 tokenFilled, uint256 usdcUsed) {
        uint256 remainUsdcAmount = marketOrderMem.remainUsdcAmount;
        uint256 remainTotalWeight = totalWeight;

        for (uint256 k = start; k < end && remainUsdcAmount > 0; k++) {
            Order storage sellOrder = orders[activeOrderIds[OrderType.SELL][k]];
            if (isInvalidOrder(sellOrder)) continue;

            uint256 weight = nowTime - sellOrder.createdAt;
            if (weight == 0) weight = 1;

            uint256 usdcShare = (remainUsdcAmount * weight) / remainTotalWeight;
            uint256 tokenQty = (usdcShare * 10 ** price_decimals) /
                currentPrice;

            if (tokenQty > sellOrder.remainTokenAmount) {
                tokenQty = sellOrder.remainTokenAmount;
                usdcShare = (tokenQty * currentPrice) / 10 ** price_decimals;
            }

            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                usdcShare,
                OrderType.SELL
            );
            usdc.safeTransfer(sellOrder.trader, realAmount);
            usdc.safeTransfer(treasury, feeAmount);

            sellOrder.remainTokenAmount -= tokenQty;
            sellOrder.lastTradeTimestamp = block.timestamp;

            if (sellOrder.remainTokenAmount == 0) {
                sellOrder.isFilled = true;
            }

            tokenFilled += tokenQty;
            usdcUsed += usdcShare;
            remainTotalWeight -= weight;
            remainUsdcAmount -= usdcShare;
        }
    }

    function removeLastFromSellLimitOrder() internal {
        uint256 lastOrderId = activeOrderIds[OrderType.SELL][activeOrderIds[OrderType.SELL].length - 1];
        activeOrderIds[OrderType.SELL].pop();
        fulfilledOrderIds.push(lastOrderId);
    }

    /**
     * @dev Create new sell market order which will be executed instantly
     */
    function createSellMarketOrder(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "Invalid Token Amount");

        token.safeTransferFrom(msg.sender, address(this), tokenAmount);

        Order memory marketOrder = Order(
            nonce,
            msg.sender,
            OrderType.SELL,
            0,
            tokenAmount,
            tokenAmount,
            0,
            0,
            false,
            true,
            false,
            0,
            0,
            block.timestamp
        );

        nonce++;

        require(activeOrderIds[OrderType.BUY].length > 0, "No active buy orders");

        uint256 totalUsdc = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeOrderIds[OrderType.BUY].length;
            i > 0 && marketOrder.remainTokenAmount > 0;

        ) {
            uint256 currentPrice = orders[activeOrderIds[OrderType.BUY][i - 1]].desiredPrice;
            uint256 j = i;

            while (
                j > 0 && orders[activeOrderIds[OrderType.BUY][j - 1]].desiredPrice == currentPrice
            ) {
                j--;
            }

            uint256 start = j;
            uint256 end = i;

            // Compute total time weight for this price group
            uint256 totalWeight = 0;
            for (uint256 k = start; k < end; k++) {
                Order memory o = orders[activeOrderIds[OrderType.BUY][k]];
                if (!isInvalidOrder(o)) {
                    uint256 w = nowTime - o.createdAt;
                    if (w == 0) w = 1;
                    totalWeight += w;
                }
            }

            // Apply time-weighted matching
            (
                uint256 usdcFilled,
                uint256 tokenAmountFilled
            ) = distributeSellOrderAcrossPriceLevel(
                    marketOrder,
                    currentPrice,
                    start,
                    end,
                    totalWeight,
                    nowTime
                );

            totalUsdc += usdcFilled;
            marketOrder.remainTokenAmount -= tokenAmountFilled;

            i = start;
        }

        if (marketOrder.remainTokenAmount > 0) {
            revert("Insufficient USDC supply");
        }

        orders[nonce] = marketOrder;
        fulfilledOrderIds.push(nonce);
        ordersByUser[msg.sender].push(nonce);
        cleanLimitOrders();

        (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
            totalUsdc,
            OrderType.SELL
        );
        usdc.safeTransfer(marketOrder.trader, realAmount);
        usdc.safeTransfer(treasury, feeAmount);
    }

    function distributeSellOrderAcrossPriceLevel(
        Order memory marketOrderMem,
        uint256 currentPrice,
        uint256 start,
        uint256 end,
        uint256 totalWeight,
        uint256 nowTime
    ) internal returns (uint256 usdcFilled, uint256 tokenAmountFilled) {
        uint256 remainTokenAmount = marketOrderMem.remainTokenAmount;
        uint256 remainTotalWeight = totalWeight;

        for (
            uint256 k = start;
            k < end && remainTokenAmount > 0;
            k++
        ) {
            Order storage buyOrder = orders[activeOrderIds[OrderType.BUY][k]];
            if (isInvalidOrder(buyOrder)) continue;

            uint256 weight = nowTime - buyOrder.createdAt;
            if (weight == 0) weight = 1;

            uint256 share = (remainTokenAmount * weight) /
                remainTotalWeight;
            if (share > buyOrder.remainTokenAmount) {
                share = buyOrder.remainTokenAmount;
            }

            uint256 usdcAmount = (share * currentPrice) / 10 ** price_decimals;
            if (usdcAmount > buyOrder.remainUsdcAmount) {
                usdcAmount = buyOrder.remainUsdcAmount;
                share = (usdcAmount * 10 ** price_decimals) / currentPrice;
            }

            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                share,
                OrderType.BUY
            );
            token.safeTransfer(buyOrder.trader, realAmount);
            token.safeTransfer(treasury, feeAmount);

            buyOrder.remainTokenAmount -= share;
            buyOrder.remainUsdcAmount -= usdcAmount;
            buyOrder.lastTradeTimestamp = block.timestamp;

            if (buyOrder.remainTokenAmount == 0) {
                buyOrder.isFilled = true;
            }

            usdcFilled += usdcAmount;
            tokenAmountFilled += share;

            remainTotalWeight -= weight;
            remainTokenAmount -= share;
        }
    }

    function removeLastFromBuyLimitOrder() internal {
        uint256 lastOrderId = activeOrderIds[OrderType.BUY][activeOrderIds[OrderType.BUY].length - 1];
        activeOrderIds[OrderType.BUY].pop();
        fulfilledOrderIds.push(lastOrderId);
    }

    /**
     * @dev Create new limit order
     */
    function createLimitOrder(
        uint256 desiredPrice,
        uint256 tokenAmount,
        uint256 validTo,
        OrderType orderType
    ) external nonReentrant {
        uint256 usdcAmount = (desiredPrice * tokenAmount) /
            10 ** price_decimals;
        Order memory newOrder;

        if (orderType == OrderType.BUY) {
            usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
            newOrder = Order(
                nonce,
                msg.sender,
                OrderType.BUY,
                desiredPrice,
                tokenAmount,
                tokenAmount,
                usdcAmount,
                usdcAmount,
                false,
                false,
                false,
                validTo,
                0,
                block.timestamp
            );
        } else {
            token.safeTransferFrom(msg.sender, address(this), tokenAmount);
            newOrder = Order(
                nonce,
                msg.sender,
                OrderType.SELL,
                desiredPrice,
                tokenAmount,
                tokenAmount,
                0,
                0,
                false,
                false,
                false,
                validTo,
                0,
                block.timestamp
            );
        }

        require(validTo > block.timestamp, "Invalid time limit");

        nonce++;

        uint256 nowTime = block.timestamp;

        // Try to match with opposite orders at the same or better price
        if (orderType == OrderType.BUY) {
            // match with lowest priced sells ≤ desiredPrice
            for (
                uint256 i = activeOrderIds[OrderType.SELL].length;
                i > 0 && newOrder.remainTokenAmount > 0;

            ) {
                uint256 currentOrderId = activeOrderIds[OrderType.SELL][i - 1];
                Order storage sellOrder = orders[currentOrderId];
                if (
                    isInvalidOrder(sellOrder) ||
                    sellOrder.desiredPrice > desiredPrice
                ) {
                    i--;
                    continue;
                }

                // Find price group
                uint256 currentPrice = sellOrder.desiredPrice;
                uint256 j = i;
                while (
                    j > 0 &&
                    orders[activeOrderIds[OrderType.SELL][j - 1]].desiredPrice == currentPrice
                ) {
                    j--;
                }

                // Weight calc
                uint256 totalWeight = 0;
                for (uint256 k = j; k < i; k++) {
                    Order memory o = orders[activeOrderIds[OrderType.SELL][k]];
                    if (!isInvalidOrder(o)) {
                        uint256 w = nowTime - o.createdAt;
                        if (w == 0) w = 1;
                        totalWeight += w;
                    }
                }

                // Time-weighted distribution
                (
                    uint256 tokenFilled,
                    uint256 usdcUsed
                ) = distributeBuyOrderAcrossPriceLevel(
                        newOrder,
                        currentPrice,
                        j,
                        i,
                        totalWeight,
                        nowTime
                    );

                newOrder.remainTokenAmount -= tokenFilled;
                newOrder.remainUsdcAmount -= usdcUsed;

                i = j;
            }

            // If partially filled, insert the rest
            if (newOrder.remainTokenAmount > 0) {
                insertBuyLimitOrder(nonce);
            } else {
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
                    isInvalidOrder(buyOrder) ||
                    buyOrder.desiredPrice < desiredPrice
                ) {
                    i--;
                    continue;
                }

                uint256 currentPrice = buyOrder.desiredPrice;
                uint256 j = i;
                while (
                    j > 0 && orders[activeOrderIds[OrderType.BUY][j - 1]].desiredPrice == currentPrice
                ) {
                    j--;
                }

                uint256 totalWeight = 0;
                for (uint256 k = j; k < i; k++) {
                    Order memory o = orders[activeOrderIds[OrderType.BUY][k]];
                    if (!isInvalidOrder(o)) {
                        uint256 w = nowTime - o.createdAt;
                        if (w == 0) w = 1;
                        totalWeight += w;
                    }
                }

                // Time-weighted distribution
                (
                    ,
                    uint256 tokenAmountFilled
                ) = distributeSellOrderAcrossPriceLevel(
                        newOrder,
                        currentPrice,
                        j,
                        i,
                        totalWeight,
                        nowTime
                    );

                newOrder.remainTokenAmount -= tokenAmountFilled;
                // newOrder.remainUsdcAmount -= usdcFilled;

                i = j;
            }

            // If partially filled, insert the rest
            if (newOrder.remainTokenAmount > 0) {
                insertSellLimitOrder(nonce);
            } else {
                orders[nonce] = newOrder;
                fulfilledOrderIds.push(nonce);
            }
        }

        orders[nonce] = newOrder;
        ordersByUser[msg.sender].push(nonce);
        cleanLimitOrders();
    }

    function insertBuyLimitOrder(uint256 orderId) internal {
        Order memory newLimitBuyOrder = orders[orderId];
        uint256 i = activeOrderIds[OrderType.BUY].length;

        activeOrderIds[OrderType.BUY].push(orderId);
        while (
            i > 0 &&
            orders[activeOrderIds[OrderType.BUY][i - 1]].desiredPrice > newLimitBuyOrder.desiredPrice
        ) {
            activeOrderIds[OrderType.BUY][i] = activeOrderIds[OrderType.BUY][i - 1];
            i--;
        }

        activeOrderIds[OrderType.BUY][i] = orderId;
    }

    function insertSellLimitOrder(uint256 orderId) internal {
        Order memory newLimitSellOrder = orders[orderId];
        uint256 i = activeOrderIds[OrderType.SELL].length;

        activeOrderIds[OrderType.SELL].push(orderId);

        while (
            i > 0 &&
            orders[activeOrderIds[OrderType.SELL][i - 1]].desiredPrice <
            newLimitSellOrder.desiredPrice
        ) {
            activeOrderIds[OrderType.SELL][i] = activeOrderIds[OrderType.SELL][i - 1];
            i--;
        }

        activeOrderIds[OrderType.SELL][i] = orderId;
    }

    function isInvalidOrder(Order memory order) public view returns (bool) {
        return
            order.isCanceled ||
            order.isFilled ||
            order.validTo < block.timestamp ||
            order.remainTokenAmount == 0;
    }

    function cleanLimitOrders() internal {
        while (
            activeOrderIds[OrderType.BUY].length > 0 &&
            isInvalidOrder(orders[activeOrderIds[OrderType.BUY][activeOrderIds[OrderType.BUY].length - 1]])
        ) {
            removeLastFromBuyLimitOrder();
        }
        while (
            activeOrderIds[OrderType.SELL].length > 0 &&
            isInvalidOrder(orders[activeOrderIds[OrderType.SELL][activeOrderIds[OrderType.SELL].length - 1]])
        ) {
            removeLastFromSellLimitOrder();
        }
    }

    function getLatestRate()
        external
        view
        returns (
            RecentOrder memory bestBidOrder,
            RecentOrder memory bestAskOrder
        )
    {
        (, uint256 price) = priceOracle.getLatestRoundData();

        if (activeOrderIds[OrderType.BUY].length > 0) {
            Order memory order = orders[activeOrderIds[OrderType.BUY][activeOrderIds[OrderType.BUY].length - 1]];
            bestBidOrder = RecentOrder(
                price * order.desiredPrice,
                order.desiredPrice,
                order.remainTokenAmount
            );
        }

        if (activeOrderIds[OrderType.SELL].length > 0) {
            Order memory order = orders[activeOrderIds[OrderType.SELL][activeOrderIds[OrderType.SELL].length - 1]];
            bestAskOrder = RecentOrder(
                price * order.desiredPrice,
                order.desiredPrice,
                order.remainTokenAmount
            );
        }
    }

    function getOrderBook(
        uint256 depth,
        OrderType orderType
    ) external view returns (uint256, Order[] memory) {
        (, uint256 price) = priceOracle.getLatestRoundData();
        if (orderType == OrderType.BUY) {
            Order[] memory bestActiveBuyOrders = new Order[](depth);
            for (
                uint256 i = activeOrderIds[OrderType.BUY].length - 1;
                i >= activeOrderIds[OrderType.BUY].length - depth;
                i--
            ) {
                bestActiveBuyOrders[i] = orders[activeOrderIds[OrderType.BUY][i]];
            }
            return (price, bestActiveBuyOrders);
        } else {
            Order[] memory bestActiveSellOrders = new Order[](depth);
            for (
                uint256 i = activeOrderIds[OrderType.SELL].length - 1;
                i >= activeOrderIds[OrderType.SELL].length - depth;
                i--
            ) {
                bestActiveSellOrders[i] = orders[activeOrderIds[OrderType.SELL][i]];
            }
            return (price, bestActiveSellOrders);
        }
    }

    function getOrderById(uint256 id) public view returns (Order memory) {
        require(id > 0 && id < nonce, "Invalid Id");
        return orders[id];
    }

    function cancelOrder(uint256 id) external returns (bool) {
        require(id < nonce, "Invalid Id");

        (OrderType orderType, uint256 i) = getIndex(id);
        Order storage order = orderType == OrderType.BUY
            ? orders[activeOrderIds[OrderType.BUY][i]]
            : orders[activeOrderIds[OrderType.SELL][i]];
        require(order.trader == msg.sender, "Not owner of Order");

        order.isCanceled = true;

        if (orderType == OrderType.BUY) {
            usdc.safeTransfer(order.trader, order.remainUsdcAmount);
        } else {
            token.safeTransfer(order.trader, order.remainTokenAmount);
        }

        return true;
    }

    function getIndex(uint256 id) public view returns (OrderType, uint256) {
        for (uint256 i = 0; i < activeOrderIds[OrderType.BUY].length; i++) {
            if (id == activeOrderIds[OrderType.BUY][i]) {
                return (OrderType.BUY, i);
            }
        }

        for (uint256 i = 0; i < activeOrderIds[OrderType.SELL].length; i++) {
            if (id == activeOrderIds[OrderType.SELL][i]) {
                return (OrderType.SELL, i);
            }
        }
        revert("Invalid Id");
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

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid address");
        priceOracle = IOracle(_oracle);
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
