package com.example.connectors.framework;

import io.micrometer.core.instrument.MeterRegistry;

import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.info.InfoContributor;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.health.contributor.HealthIndicator;
import org.springframework.boot.micrometer.metrics.autoconfigure.MeterRegistryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.ConfigurableEnvironment;

/**
 * Wires the framework into every app built on it: identity, {@code connector.*} binding and validation,
 * the start-up summary, identity tags on every meter, the readiness indicator {@code app}, the
 * identity in the {@code app} section of {@code /actuator/info} and the {@code appconfig} endpoint (ADR-0040).
 */
@AutoConfiguration
@EnableConfigurationProperties(ConnectorProperties.class)
public class AppRuntimeAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    ConnectorIdentity connectorIdentity(ConfigurableEnvironment environment) {
        return ConnectorIdentity.from(environment);
    }

    @Bean
    ConnectorStartupReporter connectorStartupReporter(ConnectorIdentity identity) {
        return new ConnectorStartupReporter(identity);
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnClass({ MeterRegistry.class, MeterRegistryCustomizer.class })
    static class MetricsConfiguration {

        /** Common tags {@code env, flow, app, instance} on every meter (ADR-0015). */
        @Bean
        MeterRegistryCustomizer<MeterRegistry> connectorIdentityTags(ConnectorIdentity identity) {
            return registry -> identity.asTags().forEach((key, value) -> registry.config().commonTags(key, value));
        }
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnClass(HealthIndicator.class)
    static class HealthConfiguration {

        /** The bean name gives the contributor its name: {@code app}, in the readiness group (ADR-0040). */
        @Bean
        AppHealthIndicator appHealthIndicator(ConnectorIdentity identity, ConnectorProperties properties) {
            return new AppHealthIndicator(identity, properties);
        }
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnClass({ InfoContributor.class, Endpoint.class })
    static class ActuatorConfiguration {

        @Bean
        AppInfoContributor appInfoContributor(ConnectorIdentity identity) {
            return new AppInfoContributor(identity);
        }

        @Bean
        AppConfigEndpoint appConfigEndpoint(ConfigurableEnvironment environment, ConnectorIdentity identity) {
            return new AppConfigEndpoint(environment, identity);
        }
    }
}
