package dev.codewithsam.shop;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;

@Entity
public class Product {

    @Id
    private String sku;
    private String name;
    @Column(length = 2000)
    private String description;
    private long price;

    protected Product() {
    }

    public Product(String sku, String name, String description, long price) {
        this.sku = sku;
        this.name = name;
        this.description = description;
        this.price = price;
    }

    public String getSku() { return sku; }
    public String getName() { return name; }
    public String getDescription() { return description; }
    public long getPrice() { return price; }
}
