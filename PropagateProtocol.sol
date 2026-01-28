// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PropagateToken is ERC20, Ownable {
    // 总供应量：1万亿（1,000,000,000,000）带18位小数
    uint256 private constant TOTAL_SUPPLY_TOKENS = 1e12 * 1e18; // 1,000,000,000,000 * 10^18
    
    // 固定兑换率：1 MON = 10,000 PPT
    uint256 private constant FIXED_RATE = 10000;
    
    // 税费设置
    uint256 private constant TAX_DENOMINATOR = 10000; // 100% = 10000
    uint256 private constant TAX_RATE = 100;          // 1% = 100/10000
    uint256 private constant BURN_RATE = 50;          // 0.5% 销毁
    uint256 private constant PRIZE_POOL_RATE = 50;    // 0.5% 奖池
    
    // 奖池抽奖设置
    uint256 private constant PRIZE_CHANCE_DENOMINATOR = 10000; // 0.01% 中奖概率
    uint256 private constant PRIZE_WIN_RATE = 100;             // 1% of pool to winner
    
    // 状态变量
    uint256 public totalSwapped;        // 已兑换总量
    uint256 public tokenPrizePool;      // PPT奖池
    uint256 public totalBurned;         // 总销毁量
    uint256 public totalTransfers;      // 总转账次数
    uint256 public lastPrizeTime;       // 上次中奖时间
    
    // 事件
    event Swapped(address indexed user, uint256 monAmount, uint256 pptAmount);
    event PrizeWon(address indexed winner, uint256 tokenPrize, uint256 monPrize);
    event TokensBurned(uint256 amount);
    event DonationReceived(address donor, uint256 amount, bool isMon);
    
    // 构造函数 - 初始化代币
    constructor() ERC20("Propagate Protocol Token", "PPT") Ownable(msg.sender) {
        // 1. 部署者获得 11% (110B PPT)
        uint256 deployerShare = TOTAL_SUPPLY_TOKENS * 11 / 100;
        
        // 2. 流动性/营销地址获得 49% (490B PPT) 
        uint256 marketingShare = TOTAL_SUPPLY_TOKENS * 49 / 100;
        
        // 3. 合约保留 40% (400B PPT) 用于兑换池
        uint256 swapPoolShare = TOTAL_SUPPLY_TOKENS - deployerShare - marketingShare;
        
        // 铸造代币
        _mint(msg.sender, deployerShare);
        _mint(msg.sender, marketingShare); // 先给部署者，可以后续转移
        _mint(address(this), swapPoolShare); // 合约自己保留40%用于兑换
        
        // 记录初始状态
        totalSwapped = 0;
        tokenPrizePool = 0;
        totalBurned = 0;
        totalTransfers = 0;
        lastPrizeTime = block.timestamp;
    }
    
    // 兑换函数 - 用户发送MON，接收PPT
    function swap() external payable {
        require(msg.value > 0, "Must send MON to swap");
        require(msg.value >= 0.001 ether, "Minimum swap is 0.001 MON");
        
        // 计算应得的PPT数量
        uint256 pptAmount = msg.value * FIXED_RATE; // 1 MON = 10000 PPT
        
        // 检查合约是否有足够的PPT余额
        uint256 contractPPTBalance = balanceOf(address(this));
        require(contractPPTBalance >= pptAmount, "Insufficient PPT in swap pool");
        
        // 检查是否超过兑换池限制（不超过合约初始40%的95%，保留5%作为缓冲）
        uint256 maxSwapPool = TOTAL_SUPPLY_TOKENS * 40 / 100;
        uint256 swapPoolLimit = maxSwapPool * 95 / 100; // 95% of swap pool
        require(totalSwapped + pptAmount <= swapPoolLimit, "Swap pool limit reached");
        
        // 更新状态
        totalSwapped += pptAmount;
        
        // 从合约转账PPT给用户
        _transfer(address(this), msg.sender, pptAmount);
        
        // 发射事件
        emit Swapped(msg.sender, msg.value, pptAmount);
    }
    
    // 重写transfer函数 - 添加税费和抽奖逻辑
    function transfer(address to, uint256 amount) public override returns (bool) {
        address sender = _msgSender();
        
        // 检查发送者余额
        require(balanceOf(sender) >= amount, "Insufficient PPT balance");
        
        // 计算税费
        uint256 taxAmount = amount * TAX_RATE / TAX_DENOMINATOR;
        uint256 netAmount = amount - taxAmount;
        
        if (taxAmount > 0) {
            // 1% 税费分配
            uint256 burnAmount = taxAmount * BURN_RATE / TAX_RATE; // 0.5% 销毁
            uint256 prizeAmount = taxAmount - burnAmount;         // 0.5% 奖池
            
            // 执行销毁
            if (burnAmount > 0) {
                _burn(sender, burnAmount);
                totalBurned += burnAmount;
                emit TokensBurned(burnAmount);
            }
            
            // 增加奖池
            if (prizeAmount > 0) {
                // 先从发送者转账到合约（奖池）
                _transfer(sender, address(this), prizeAmount);
                tokenPrizePool += prizeAmount;
            }
        }
        
        // 转账净额给接收者
        _transfer(sender, to, netAmount);
        
        // 更新转账计数
        totalTransfers++;
        
        // 抽奖逻辑 - 0.01% 中奖概率
        if (shouldDistributePrize(to)) {
            _distributePrize(to);
        }
        
        return true;
    }
    
    // 重写transferFrom函数
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        
        // 检查发送者余额
        require(balanceOf(from) >= amount, "Insufficient PPT balance");
        
        // 计算税费
        uint256 taxAmount = amount * TAX_RATE / TAX_DENOMINATOR;
        uint256 netAmount = amount - taxAmount;
        
        if (taxAmount > 0) {
            // 1% 税费分配
            uint256 burnAmount = taxAmount * BURN_RATE / TAX_RATE; // 0.5% 销毁
            uint256 prizeAmount = taxAmount - burnAmount;         // 0.5% 奖池
            
            // 执行销毁
            if (burnAmount > 0) {
                _burn(from, burnAmount);
                totalBurned += burnAmount;
                emit TokensBurned(burnAmount);
            }
            
            // 增加奖池
            if (prizeAmount > 0) {
                // 先从发送者转账到合约（奖池）
                _transfer(from, address(this), prizeAmount);
                tokenPrizePool += prizeAmount;
            }
        }
        
        // 转账净额给接收者
        _transfer(from, to, netAmount);
        
        // 更新转账计数
        totalTransfers++;
        
        // 抽奖逻辑 - 0.01% 中奖概率
        if (shouldDistributePrize(to)) {
            _distributePrize(to);
        }
        
        return true;
    }
    
    // 检查是否应该分发奖池
    function shouldDistributePrize(address to) private view returns (bool) {
        // 确保有奖池余额
        if (tokenPrizePool == 0) return false;
        
        // 确保至少1小时没有中奖（防止频繁中奖）
        if (block.timestamp - lastPrizeTime < 1 hours) return false;
        
        // 0.01% 中奖概率
        uint256 random = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            to,
            totalTransfers
        )));
        
        return (random % PRIZE_CHANCE_DENOMINATOR == 0);
    }
    
    // 分发奖池奖励
    function _distributePrize(address winner) private {
        // 计算奖励：1% 的PPT奖池和1% 的MON奖池
        uint256 pptPrize = tokenPrizePool * PRIZE_WIN_RATE / TAX_DENOMINATOR;
        uint256 monPrize = address(this).balance * PRIZE_WIN_RATE / TAX_DENOMINATOR;
        
        // 确保有奖励可分发
        require(pptPrize > 0 || monPrize > 0, "No prize to distribute");
        
        // 分发PPT奖励
        if (pptPrize > 0 && pptPrize <= tokenPrizePool) {
            tokenPrizePool -= pptPrize;
            _transfer(address(this), winner, pptPrize);
        }
        
        // 分发MON奖励
        if (monPrize > 0 && monPrize <= address(this).balance) {
            (bool success, ) = winner.call{value: monPrize}("");
            require(success, "MON prize transfer failed");
        }
        
        // 更新最后中奖时间
        lastPrizeTime = block.timestamp;
        
        // 发射事件
        emit PrizeWon(winner, pptPrize, monPrize);
    }
    
    // 获取合约统计数据
    function getStats() external view returns (
        uint256 totalSupply,
        uint256 swapped,
        uint256 tokenPrizePoolAmount,
        uint256 burned,
        uint256 currentRate,
        uint256 contractMonBalance,
        uint256 contractPptBalance,
        uint256 transfersCount
    ) {
        return (
            TOTAL_SUPPLY_TOKENS,
            totalSwapped,
            tokenPrizePool,
            totalBurned,
            FIXED_RATE,
            address(this).balance,
            balanceOf(address(this)),
            totalTransfers
        );
    }
    
    // 获取当前兑换率（固定）
    function getCurrentRate() public pure returns (uint256) {
        return FIXED_RATE;
    }
    
    // 获取合约剩余可兑换的PPT数量
    function getRemainingSwapPool() public view returns (uint256) {
        uint256 maxSwapPool = TOTAL_SUPPLY_TOKENS * 40 / 100;
        uint256 swapPoolLimit = maxSwapPool * 95 / 100; // 95% of swap pool
        if (totalSwapped >= swapPoolLimit) {
            return 0;
        }
        return swapPoolLimit - totalSwapped;
    }
    
    // 获取当前中奖概率信息
    function getPrizeInfo() external view returns (
        uint256 prizePoolPPT,
        uint256 prizePoolMON,
        uint256 chancePercent,
        uint256 timeSinceLastPrize
    ) {
        return (
            tokenPrizePool,
            address(this).balance,
            PRIZE_CHANCE_DENOMINATOR, // 返回分母，前端计算概率
            block.timestamp - lastPrizeTime
        );
    }
    
    // 所有者可以提取合约中的MON（用于项目发展）
    function withdrawMon(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient MON balance");
        (bool success, ) = owner().call{value: amount}("");
        require(success, "Withdrawal failed");
    }
    
    // 所有者可以提取合约中多余的PPT（如果合约意外收到PPT）
    function withdrawPpt(uint256 amount) external onlyOwner {
        uint256 contractBalance = balanceOf(address(this));
        // 确保不会提取兑换池的PPT
        uint256 swapPoolBalance = getRemainingSwapPool() + (TOTAL_SUPPLY_TOKENS * 40 / 100 * 5 / 100); // 包括缓冲的5%
        uint256 withdrawable = contractBalance > swapPoolBalance ? contractBalance - swapPoolBalance : 0;
        
        require(amount <= withdrawable, "Cannot withdraw from swap pool");
        _transfer(address(this), owner(), amount);
    }
    
    // 捐赠函数 - 用户可以直接捐赠MON到奖池
    function donateMon() external payable {
        require(msg.value > 0, "Must send MON to donate");
        emit DonationReceived(msg.sender, msg.value, true);
    }
    
    // 接收MON的fallback函数
    receive() external payable {
        // 默认视为捐赠
        emit DonationReceived(msg.sender, msg.value, true);
    }
}