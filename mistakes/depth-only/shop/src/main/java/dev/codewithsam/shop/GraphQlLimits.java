package dev.codewithsam.shop;

import graphql.analysis.MaxQueryDepthInstrumentation;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

// Depth only. Nothing limits how wide a query is.
@Configuration
public class GraphQlLimits {

    @Bean
    public MaxQueryDepthInstrumentation maxDepth() {
        return new MaxQueryDepthInstrumentation(6);
    }
}
