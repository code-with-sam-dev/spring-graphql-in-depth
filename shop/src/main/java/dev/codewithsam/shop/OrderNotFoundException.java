package dev.codewithsam.shop;

public class OrderNotFoundException extends RuntimeException {

    public OrderNotFoundException(Long id) {
        super("No order " + id);
    }
}
