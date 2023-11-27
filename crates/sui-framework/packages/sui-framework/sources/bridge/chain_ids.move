module sui::chain_ids {

    // Chain IDs
    const SUI: u8 = 0;
    const BTC: u8 = 1;
    const ETH: u8 = 2;

    public fun sui(): u8 {
        SUI
    }

    public fun btc(): u8 {
        BTC
    }

    public fun eth(): u8 {
        ETH
    }
}