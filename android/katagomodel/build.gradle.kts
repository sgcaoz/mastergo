plugins {
    id("com.android.asset-pack")
}

assetPack {
    packName = "katagomodel"
    dynamicDelivery {
        deliveryType = "fast-follow"
    }
}
