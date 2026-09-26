package dev.codewithsam.shop;

import java.util.List;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

// The same data the REST way: the server decides the shape of each response.
@RestController
@RequestMapping("/api")
public class OrderRestController {

    public record OrderSummary(Long id, OrderStatus status, long total, Long customerId) {
    }

    public record LineDetail(String sku, String name, String description, int quantity,
                             long unitPrice) {
    }

    public record OrderDetail(Long id, OrderStatus status, long total, Customer customer,
                              List<LineDetail> lines) {
    }

    private final OrderRepository orders;
    private final OrderLineRepository lines;
    private final CustomerRepository customers;
    private final ProductRepository products;

    public OrderRestController(OrderRepository orders, OrderLineRepository lines,
                               CustomerRepository customers, ProductRepository products) {
        this.orders = orders;
        this.lines = lines;
        this.customers = customers;
        this.products = products;
    }

    @GetMapping("/orders")
    public List<OrderSummary> list() {
        return orders.findTop20ByOrderById().stream()
                .map(o -> new OrderSummary(o.getId(), o.getStatus(), o.getTotal(),
                        o.getCustomerId()))
                .toList();
    }

    @GetMapping("/orders/{id}")
    public OrderDetail detail(@PathVariable Long id) {
        Order order = orders.findById(id).orElseThrow(() -> new OrderNotFoundException(id));
        List<LineDetail> detail = lines.findByOrderId(id).stream()
                .map(line -> {
                    Product product = products.findById(line.getSku()).orElseThrow();
                    return new LineDetail(line.getSku(), product.getName(),
                            product.getDescription(), line.getQuantity(), line.getUnitPrice());
                })
                .toList();
        return new OrderDetail(order.getId(), order.getStatus(), order.getTotal(),
                customers.findById(order.getCustomerId()).orElseThrow(), detail);
    }

    @GetMapping("/customers/{id}")
    public Customer customer(@PathVariable Long id) {
        return customers.findById(id).orElseThrow();
    }
}
