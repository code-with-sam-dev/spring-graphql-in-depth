package dev.codewithsam.shop;

import java.util.List;

public record PlaceOrderInput(Long customerId, List<LineInput> lines) {

    public record LineInput(String sku, int quantity) {
    }
}
