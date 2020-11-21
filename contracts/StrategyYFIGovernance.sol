/**
 *Submitted for verification at Etherscan.io on 2020-09-24
 */

// SPDX-License-Identifier: MIT

pragma solidity ^0.5.17;

import "./common.sol";

/*

 A strategy must implement the following calls;
 
 - deposit()
 - withdraw(address) must exclude any tokens used in the yield - Controller role - withdraw should return to Controller
 - withdraw(uint) - Controller | Vault role - withdraw should always return to vault
 - withdrawAll() - Controller | Vault role - withdraw should always return to vault
 - balanceOf()
 
 Where possible, strategies must remain as immutable as possible, instead of updating variables, we update the contract by linking it in the controller
 
*/

//一些接口合约：Governance, yERC20, Uni, ICurveFi, Zap
interface Governance {
    function withdraw(uint256) external;

    function getReward() external;

    function stake(uint256) external;

    function balanceOf(address) external view returns (uint256);

    function exit() external;

    function voteFor(uint256) external;

    function voteAgainst(uint256) external;
}

interface yERC20 {
    function deposit(uint256 _amount) external;

    function withdraw(uint256 _amount) external;
}

interface Uni {
    function swapExactTokensForTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external;
}

interface ICurveFi {
    function get_virtual_price() external view returns (uint256);

    function add_liquidity(uint256[4] calldata amounts, uint256 min_mint_amount)
        external;

    function remove_liquidity_imbalance(
        uint256[4] calldata amounts,
        uint256 max_burn_amount
    ) external;

    function remove_liquidity(uint256 _amount, uint256[4] calldata amounts)
        external;

    function exchange(
        int128 from,
        int128 to,
        uint256 _from_amount,
        uint256 _min_to_amount
    ) external;
}

interface Zap {
    function remove_liquidity_one_coin(
        uint256,
        int128,
        uint256
    ) external;
}


/**
 *yearn vaults中的YFI vault:使用者存入YFI代币，获得yYFI代币，赎回yYFI代币时可获取原本投入的YFI代币加上策略赚取的YFI代币;
 *本合约是YFI vault的策略合约，合约收到YFI后，将YFI stake到ygov.finance,从而赚取收益;
 *收益来源：yearn v2 机枪池所收到的费用去了专门的国库合约（限额50万美元），超过限额将会自动到治理合约,stake YFI到治理合约能赚取这部分收益;
 *YFI策略合约 地址:0x395F93350D5102B6139Abfc84a7D6ee70488797C 有小部分更新 暂时没拉下来;
 */
contract StrategyYFIGovernance {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    //YFI代币地址
    address public constant want = address(
        0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e
    );
    //yearn governance staking 地址 
    address public constant gov = address(
        0xBa37B002AbaFDd8E89a1995dA52740bbC013D992
    );
    //Curve的y池的swap地址
    address public constant curve = address(
        0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51
    );
    //Curve的y池的deposit地址
    address public constant zap = address(
        0xbBC81d23Ea2c3ec7e56D39296F0cbB648873a5d3
    );
    //yCrv Token地址
    address public constant reward = address(
        0xdF5e0e81Dff6FAF3A7e52BA697820c5e32D806A8
    );
    //usdt地址
    address public constant usdt = address(
        0xdAC17F958D2ee523a2206206994597C13D831ec7
    );

    // Uniswap V2: Router 2
    // Uniswao V2 路由2 地址
    address public constant uni = address(
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
    );
    //weth 地址
    address public constant weth = address(
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    ); // used for crv <> weth <> dai route

    //5%的绩效费用
    uint256 public fee = 500;
    //最大值100% 各项费率基准值
    uint256 public constant max = 10000;

    //治理地址:用于治理权限检验
    address public governance;
    //控制器地址:用于与本合约的资金交互
    address public controller;
    //策略管理员地址:用于权限检验和发放策略管理费
    address public strategist;

    /**
     *@dev    构造函数，初始化时调用，部署合约时，只设置一个控制器地址，其他默认为部署地址；
     *@param  控制器地址;
     */
    constructor(address _controller) public {
        governance = msg.sender;
        strategist = msg.sender;
        controller = _controller;
    }

    /**
     *@dev 设置费用
     *@param _fee 费用值
     */
    function setFee(uint256 _fee) external {
        //确保合约调用者为治理人员
        require(msg.sender == governance, "!governance");
        fee = _fee;
    }

    /**
     *@dev 设置策略管理员地址
     *@param _strategist 策略管理员地址
     */
    function setStrategist(address _strategist) external {
        //确保合约调用者为治理人员
        require(msg.sender == governance, "!governance");
        strategist = _strategist;
    }

    /**
     *@dev 存款处理方法
     */
    function deposit() public {
        //授权使用合约中的YFI代币
        IERC20(want).safeApprove(gov, 0);
        IERC20(want).safeApprove(gov, IERC20(want).balanceOf(address(this)));
        //把YFI stake 到governance 治理合约
        Governance(gov).stake(IERC20(want).balanceOf(address(this)));
    }

    /**
     *Controller only function for creating additional rewards from dust
     *把某一个token在本合约的余额全部取回到controller控制器合约
     */
    function withdraw(IERC20 _asset) external returns (uint256 balance) {
        //确保是控制器合约调用
        require(msg.sender == controller, "!controller");
        //不能取YFI
        require(want != address(_asset), "want");
        //取余额
        balance = _asset.balanceOf(address(this));
        //发给控制器合约
        _asset.safeTransfer(controller, balance);
    }

    /**
     *Withdraw partial funds, normally used with a vault withdrawal
     *取款方法，通常是用户从Vault取款时，Vault合约余额不够时触发
     */
    function withdraw(uint256 _amount) external {
        //确保是控制器合约调用
        require(msg.sender == controller, "!controller");
        //YFI在本合约的余额
        uint256 _balance = IERC20(want).balanceOf(address(this));
        //如果本合约余额不够
        if (_balance < _amount) {
            //赎回不够的金额
            _amount = _withdrawSome(_amount.sub(_balance));
            //实际赎回金额 + balance = 真实的用金额
            _amount = _amount.add(_balance);
        }
        //计算取款收费
        uint256 _fee = _amount.mul(fee).div(max);
        //将收到费发给奖励池-----通过controller获取相应的地址
        IERC20(want).safeTransfer(Controller(controller).rewards(), _fee);
        //从控制器合约获取保险柜地址
        address _vault = Controller(controller).vaults(address(want));
        //检验保险地址是否有误
        require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
        //扣除费用后，发送回保险柜地址
        IERC20(want).safeTransfer(_vault, _amount.sub(_fee));
    }

    /**
     *Withdraw all funds, normally used when migrating strategies
     *全部取款方法，通常是停止策略或者切换策略时调用
     */
    function withdrawAll() external returns (uint256 balance) {
        //确保是控制器合约调用
        require(msg.sender == controller, "!controller");
        //从投资池中，全部赎回
        _withdrawAll();
        //取YFI的全部余额
        balance = IERC20(want).balanceOf(address(this));
        //获取保险柜地址
        address _vault = Controller(controller).vaults(address(want));
        //检验保险地址是否有误
        require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
        //将全部的YFI发送回保险柜
        IERC20(want).safeTransfer(_vault, balance);
    }

    /**
     *@dev 从投资中全部赎回
     */
    function _withdrawAll() internal {
        Governance(gov).exit();
    }

    /**
     *@dev 收获方法
     *将治理合约中奖励的usdt换成weth，再换成YFI，继续stake到治理合约中?????
     *zap作用  curve作用？
     *
     */
    function harvest() public {
        //确保是策略管理员或治理员或tx.origin调用
        require(
            msg.sender == strategist ||
                msg.sender == governance ||
                msg.sender == tx.origin,
            "!authorized"
        );
        //执行收获操作 从治理合约收获stake产生的奖励
        Governance(gov).getReward();
        //收获usdt??
        uint256 _balance = IERC20(reward).balanceOf(address(this));
        if (_balance > 0) {
            IERC20(reward).safeApprove(zap, 0);
            IERC20(reward).safeApprove(zap, _balance);
            Zap(zap).remove_liquidity_one_coin(_balance, 2, 0);
        }
        _balance = IERC20(usdt).balanceOf(address(this));
        if (_balance > 0) {
            //授权uniswap
            IERC20(usdt).safeApprove(uni, 0);
            IERC20(usdt).safeApprove(uni, _balance);
            //uniswap的兑换路径：usdt兑换weth，weth兑换YFI
            address[] memory path = new address[](3);
            path[0] = usdt;
            path[1] = weth;
            path[2] = want;
            //执行uniswap的兑换方法
            Uni(uni).swapExactTokensForTokens(
                _balance,
                uint256(0),
                path,
                address(this),
                now.add(1800)
            );
        }
        if (IERC20(want).balanceOf(address(this)) > 0) {
            //如果余额还有YFI，继续存款;
            deposit();
        }
    }

    
    /**
     *@dev 投资中部分赎回方法
     *param _amount 赎回数量
     */
    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        Governance(gov).withdraw(_amount);
        return _amount;
    }


    /**
     *@dev 本合约的YFI余额
     */
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    /**
     *@dev 治理合约的余额
     */
    function balanceOfYGov() public view returns (uint256) {
        return Governance(gov).balanceOf(address(this));
    }

    /**
     *@dev 本策略管理的总YFI金额
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfYGov());
    }

    /**
     *@dev 投赞成票
     *@param _proposal 提案
     */
    function voteFor(uint256 _proposal) external {
        //确保是治理地址调用
        require(msg.sender == governance, "!governance");
        Governance(gov).voteFor(_proposal);
    }

    /**
     *@dev 投反对票
     *@param _proposal 提案
     */
    function voteAgainst(uint256 _proposal) external {
        //确保是治理地址调用
        require(msg.sender == governance, "!governance");
        Governance(gov).voteAgainst(_proposal);
    }
    /**
     *@dev 重新设置治理地址
     */
    function setGovernance(address _governance) external {
        //确保是治理地址调用
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }
    /**
     *@dev 重新设置控制器地址
     */
    function setController(address _controller) external {
        //确保是治理地址调用
        require(msg.sender == governance, "!governance");
        controller = _controller;
    }
}


