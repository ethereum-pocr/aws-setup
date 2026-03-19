function refill(target) {

        if (!target || !web3.isAddress(target)) {
                console.log("target account not specified:", target);
                return;
        }
        var limit=new BigNumber(web3.toWei(20, "ether"));
        var total=new BigNumber(web3.toWei(200, "ether"));
        var now=new Date().toISOString();
        var balance=eth.getBalance(target);
        console.log("balance of",target, "=", balance, "and limit =", limit)
        if (balance.lt(limit)) {
                var value = total.sub(balance);
                var tx = eth.sendTransaction({ from: eth.coinbase, to:target, value });
                console.log(now, "Crediting", target, "tx=", tx, "value", value);
        } else {
                console.log(now, "No credit");
        }

}

function swipe(target) {

        if (!target || !web3.isAddress(target)) {
                console.log("target account not specified:", target);
                return;
        }
        var keep=new BigNumber(web3.toWei(1, "ether"));
        var total=new BigNumber(web3.toWei(200, "ether"));
        var now=new Date().toISOString();
        var balance=eth.getBalance(eth.coinbase);
        console.log("balance of",eth.coinbase, "=", balance, "and we keep =", keep)
        if (balance.gt(keep)) {
                var value = balance.sub(keep);
                var tx = eth.sendTransaction({ from: eth.coinbase, to:target, value });
                console.log(now, "Crediting", target, "tx=", tx, "value", value);
        } else {
                console.log(now, "No credit");
        }

}