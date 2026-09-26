package dev.codewithsam.shop;

import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;
import org.springframework.data.domain.Limit;
import org.springframework.data.domain.ScrollPosition;
import org.springframework.data.domain.Sort;
import org.springframework.data.domain.Window;
import org.springframework.graphql.data.method.annotation.Argument;
import org.springframework.graphql.data.method.annotation.MutationMapping;
import org.springframework.graphql.data.method.annotation.QueryMapping;
import org.springframework.graphql.data.method.annotation.SchemaMapping;
import org.springframework.graphql.data.method.annotation.SubscriptionMapping;
import org.springframework.graphql.data.query.ScrollSubrange;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Controller;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Sinks;

@Controller
public class ShopController {

    private final OrderRepository orders;
    private final OrderLineRepository lines;
    private final CustomerRepository customers;
    private final ProductRepository products;
    private final OrderService service;
    private final Sinks.Many<Order> statusChanges =
            Sinks.many().multicast().onBackpressureBuffer();

    public ShopController(OrderRepository orders, OrderLineRepository lines,
                          CustomerRepository customers, ProductRepository products,
                          OrderService service) {
        this.orders = orders;
        this.lines = lines;
        this.customers = customers;
        this.products = products;
        this.service = service;
    }

    @QueryMapping
    public Order order(@Argument Long id) {
        return orders.findById(id).orElseThrow(() -> new OrderNotFoundException(id));
    }

    // first/after and last/before arrive as a ScrollSubrange; the Window that
    // comes back becomes an OrderConnection with edges, cursors and pageInfo.
    @QueryMapping
    public Window<Order> orders(ScrollSubrange subrange) {
        ScrollPosition position = subrange.position().orElse(ScrollPosition.keyset());
        int count = subrange.count().orElse(10);
        return orders.findBy(position, Limit.of(count), Sort.by("id"));
    }

    @MutationMapping
    public Order shipOrder(@Argument Long id) {
        Order order = service.ship(id);
        statusChanges.tryEmitNext(order);
        return order;
    }

    @SubscriptionMapping
    public Flux<Order> orderStatus(@Argument Long orderId) {
        return statusChanges.asFlux().filter(order -> order.getId().equals(orderId));
    }

    // One query per parent: the N plus one, three levels deep.
    @SchemaMapping
    public Customer customer(Order order) {
        return customers.findById(order.getCustomerId()).orElseThrow();
    }

    @SchemaMapping
    public List<OrderLine> lines(Order order) {
        return lines.findByOrderId(order.getId());
    }

    @SchemaMapping
    public Product product(OrderLine line) {
        return products.findById(line.getSku()).orElseThrow();
    }

    // Schema evolution: the new field is added beside the old one, and the old
    // one is deprecated rather than removed, so clients that ask for it keep working.
    @SchemaMapping
    public long amount(Order order) {
        return order.getTotal();
    }

    // Field level security: without the role this one field is null, and the
    // rest of the response still arrives.
    @SchemaMapping
    @PreAuthorize("hasRole('ADMIN')")
    public String email(Customer customer) {
        return customer.getEmail();
    }
}
