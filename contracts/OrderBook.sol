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

    Order[] public activeBuyOrders;
    Order[] public activeSellOrders;
    Order[] public fullfilledOrders;

    IERC20Upgradeable public usdc;
    IERC20Upgradeable public token;
    IOracle public priceOracle; // token-usdc price oracle

    uint256 public nonce;
    uint256 private constant BASE_BIPS = 10000;
    uint256 public buyFeeBips;
    uint256 public sellFeeBips;
    uint256 private constant price_decimals = 18;
    address public treasury;

    mapping(address => uint256) public orderCountByUser; // Add Count

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

        require(activeSellOrders.length > 0, "No active sell orders");

        uint256 totalTokens = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeSellOrders.length;
            i > 0 && marketOrder.remainUsdcAmount > 0;

        ) {
            uint256 currentPrice = activeSellOrders[i - 1].desiredPrice;
            uint256 j = i;

            while (
                j > 0 && activeSellOrders[j - 1].desiredPrice == currentPrice
            ) {
                j--;
            }

            uint256 start = j;
            uint256 end = i;

            // Compute total time weight for this price group
            uint256 totalWeight = 0;
            for (uint256 k = start; k < end; k++) {
                Order memory o = activeSellOrders[k];
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

        fullfilledOrders.push(marketOrder);
        cleanLimitOrders();

        (uint256 _realAmount, uint256 _feeAmount) = getAmountDeductFee(
            totalTokens,
            OrderType.BUY
        );
        token.safeTransfer(msg.sender, _realAmount);
        token.safeTransfer(treasury, _feeAmount);

        orderCountByUser[msg.sender]++;
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
            Order storage sellOrder = activeSellOrders[k];
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
        Order memory lastOrder = activeSellOrders[activeSellOrders.length - 1];
        activeSellOrders.pop();
        fullfilledOrders.push(lastOrder);
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

        require(activeBuyOrders.length > 0, "No active buy orders");

        uint256 totalUsdc = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeBuyOrders.length;
            i > 0 && marketOrder.remainTokenAmount > 0;

        ) {
            uint256 currentPrice = activeBuyOrders[i - 1].desiredPrice;
            uint256 j = i;

            while (
                j > 0 && activeBuyOrders[j - 1].desiredPrice == currentPrice
            ) {
                j--;
            }

            uint256 start = j;
            uint256 end = i;

            // Compute total time weight for this price group
            uint256 totalWeight = 0;
            for (uint256 k = start; k < end; k++) {
                Order memory o = activeBuyOrders[k];
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

        fullfilledOrders.push(marketOrder);
        cleanLimitOrders();

        (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
            totalUsdc,
            OrderType.SELL
        );
        usdc.safeTransfer(marketOrder.trader, realAmount);
        usdc.safeTransfer(treasury, feeAmount);

        orderCountByUser[msg.sender]++;
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
            Order storage buyOrder = activeBuyOrders[k];
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
        Order memory lastOrder = activeBuyOrders[activeBuyOrders.length - 1];
        activeBuyOrders.pop();
        fullfilledOrders.push(lastOrder);
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
                uint256 i = activeSellOrders.length;
                i > 0 && newOrder.remainTokenAmount > 0;

            ) {
                Order storage sellOrder = activeSellOrders[i - 1];
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
                    activeSellOrders[j - 1].desiredPrice == currentPrice
                ) {
                    j--;
                }

                // Weight calc
                uint256 totalWeight = 0;
                for (uint256 k = j; k < i; k++) {
                    Order memory o = activeSellOrders[k];
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
                insertBuyLimitOrder(newOrder);
            } else {
                fullfilledOrders.push(newOrder);
            }
        } else {
            // SELL order — match with highest priced buys ≥ desiredPrice
            for (
                uint256 i = activeBuyOrders.length;
                i > 0 && newOrder.remainTokenAmount > 0;

            ) {
                Order storage buyOrder = activeBuyOrders[i - 1];
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
                    j > 0 && activeBuyOrders[j - 1].desiredPrice == currentPrice
                ) {
                    j--;
                }

                uint256 totalWeight = 0;
                for (uint256 k = j; k < i; k++) {
                    Order memory o = activeBuyOrders[k];
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
                insertSellLimitOrder(newOrder);
            } else {
                fullfilledOrders.push(newOrder);
            }
        }

        cleanLimitOrders();
        orderCountByUser[msg.sender]++;
    }

    // Sort ASC [0, 1, 2, ...]
    function insertBuyLimitOrder(Order memory newLimitBuyOrder) internal {
        uint256 i = activeBuyOrders.length;

        activeBuyOrders.push(newLimitBuyOrder);
        while (
            i > 0 &&
            activeBuyOrders[i - 1].desiredPrice > newLimitBuyOrder.desiredPrice
        ) {
            activeBuyOrders[i] = activeBuyOrders[i - 1];
            i--;
        }

        activeBuyOrders[i] = newLimitBuyOrder;
    }

    // Sort DESC [9, 8, ..., 1, 0]
    function insertSellLimitOrder(Order memory newLimitSellOrder) internal {
        uint256 i = activeSellOrders.length;

        activeSellOrders.push(newLimitSellOrder);

        while (
            i > 0 &&
            activeSellOrders[i - 1].desiredPrice <
            newLimitSellOrder.desiredPrice
        ) {
            activeSellOrders[i] = activeSellOrders[i - 1];
            i--;
        }

        activeSellOrders[i] = newLimitSellOrder;
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
            activeBuyOrders.length > 0 &&
            isInvalidOrder(activeBuyOrders[activeBuyOrders.length - 1])
        ) {
            removeLastFromBuyLimitOrder();
        }
        while (
            activeSellOrders.length > 0 &&
            isInvalidOrder(activeSellOrders[activeSellOrders.length - 1])
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

        if (activeBuyOrders.length > 0) {
            Order memory order = activeBuyOrders[activeBuyOrders.length - 1];
            bestBidOrder = RecentOrder(
                price * order.desiredPrice,
                order.desiredPrice,
                order.remainTokenAmount
            );
        }

        if (activeSellOrders.length > 0) {
            Order memory order = activeSellOrders[activeSellOrders.length - 1];
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
            if (depth >= activeBuyOrders.length) {
                return (price, activeBuyOrders);
            }
            for (
                uint256 i = activeBuyOrders.length - 1;
                i >= activeBuyOrders.length - depth;
                i--
            ) {
                bestActiveBuyOrders[i] = activeBuyOrders[i];
            }
            return (price, bestActiveBuyOrders);
        } else {
            Order[] memory bestActiveSellOrders = new Order[](depth);
            if (depth >= activeSellOrders.length) {
                return (price, activeSellOrders);
            }
            for (
                uint256 i = activeSellOrders.length - 1;
                i >= activeSellOrders.length - depth;
                i--
            ) {
                bestActiveSellOrders[i] = activeBuyOrders[i];
            }
            return (price, bestActiveSellOrders);
        }
    }

    function getOrderById(uint256 id) public view returns (Order memory) {
        require(id > 0 && id < nonce, "Invalid Id");
        for (uint256 i = 0; i < activeBuyOrders.length; i++) {
            Order memory order = activeBuyOrders[i];
            if (id == order.id) {
                return order;
            }
        }
        for (uint256 i = 0; i < activeSellOrders.length; i++) {
            Order memory order = activeSellOrders[i];
            if (id == order.id) {
                return order;
            }
        }
        for (uint256 i = 0; i < fullfilledOrders.length; i++) {
            Order memory order = fullfilledOrders[i];
            if (id == order.id) {
                return order;
            }
        }

        revert("Invalid Order");
    }

    function getOrdersByUser(
        address user
    ) external view returns (Order[] memory, Order[] memory, Order[] memory) {
        require(orderCountByUser[user] > 0, "User did not make any order");
        Order[] memory activeBuyOrdersByUser = new Order[](
            orderCountByUser[user]
        );
        uint256 k;
        for (uint256 i = 0; i < activeBuyOrders.length; i++) {
            Order memory order = activeBuyOrders[i];
            if (user == order.trader) {
                activeBuyOrdersByUser[k] = order;
                k++;
            }
        }
        uint256 toDrop1 = orderCountByUser[user] - k;
        if (toDrop1 > 0) {
            assembly {
                mstore(
                    activeBuyOrdersByUser,
                    sub(mload(activeBuyOrdersByUser), toDrop1)
                )
            }
        }
        k = 0;

        Order[] memory activeSellOrdersByUser = new Order[](
            orderCountByUser[user]
        );
        for (uint256 i = 0; i < activeSellOrders.length; i++) {
            Order memory order = activeSellOrders[i];
            if (user == order.trader) {
                activeSellOrdersByUser[k] = order;
                k++;
            }
        }
        uint256 toDrop2 = orderCountByUser[user] - k;
        if (toDrop2 > 0) {
            assembly {
                mstore(
                    activeSellOrdersByUser,
                    sub(mload(activeSellOrdersByUser), toDrop2)
                )
            }
        }
        k = 0;

        Order[] memory fullfilledOrdersByUser = new Order[](
            orderCountByUser[user]
        );
        for (uint256 i = 0; i < fullfilledOrders.length; i++) {
            Order memory order = fullfilledOrders[i];
            if (user == order.trader) {
                fullfilledOrdersByUser[k] = order;
                k++;
            }
        }
        uint256 toDrop3 = orderCountByUser[user] - k;
        if (toDrop3 > 0) {
            assembly {
                mstore(
                    fullfilledOrdersByUser,
                    sub(mload(fullfilledOrdersByUser), toDrop3)
                )
            }
        }

        return (
            activeBuyOrdersByUser,
            activeSellOrdersByUser,
            fullfilledOrdersByUser
        );
    }

    function cancelOrder(uint256 id) external returns (bool) {
        require(id < nonce, "Invalid Id");

        (OrderType orderType, uint256 i) = getIndex(id);
        Order storage order = orderType == OrderType.BUY
            ? activeBuyOrders[i]
            : activeSellOrders[i];
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
        for (uint256 i = 0; i < activeBuyOrders.length; i++) {
            Order memory order = activeBuyOrders[i];
            if (id == order.id) {
                return (OrderType.BUY, i);
            }
        }

        for (uint256 i = 0; i < activeSellOrders.length; i++) {
            Order memory order = activeSellOrders[i];
            if (id == order.id) {
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
