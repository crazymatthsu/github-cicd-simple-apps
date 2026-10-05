package com.example.connectors.framework;

import java.util.Properties;

import org.junit.jupiter.api.Test;

import org.springframework.mock.env.MockEnvironment;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ConnectorIdentityTest {

    private static MockEnvironment deployed() {
        return new MockEnvironment()
                .withProperty("spring.application.name", "source-database")
                .withProperty("APP_ENV", "us-dev")
                .withProperty("APP_FLOW", "cash")
                .withProperty("APP_NAME", "source-database")
                .withProperty("APP_INSTANCE", "trades-db-to-amps");
    }

    @Test
    void readsTheFourEnvironmentVariables() {
        ConnectorIdentity identity = ConnectorIdentity.from(deployed());

        assertThat(identity.tuple()).isEqualTo("us-dev/cash/source-database/trades-db-to-amps");
        assertThat(identity.composeProject()).isEqualTo("us-dev-cash-source-database-trades-db-to-amps");
        assertThat(identity.releaseName()).isEqualTo("source-database-trades-db-to-amps");
        assertThat(identity.tablePrefix()).isEqualTo("cash_trades_db_to_amps_");
        assertThat(identity.asTags()).containsExactly(
                org.assertj.core.api.Assertions.entry("env", "us-dev"),
                org.assertj.core.api.Assertions.entry("flow", "cash"),
                org.assertj.core.api.Assertions.entry("app", "source-database"),
                org.assertj.core.api.Assertions.entry("instance", "trades-db-to-amps"));
        assertThat(identity.isComplete()).isTrue();
    }

    @Test
    void withoutADeployerTheIdentityIsLocalAndIncomplete() {
        ConnectorIdentity identity = ConnectorIdentity.from(
                new MockEnvironment().withProperty("spring.application.name", "source-kafka"));

        assertThat(identity.tuple()).isEqualTo("local/none/source-kafka/none");
        assertThat(identity.isComplete()).isFalse();
    }

    @Test
    void anotherAppsComposeEnvFailsFast() {
        MockEnvironment environment = deployed().withProperty("APP_NAME", "source-kafka");

        assertThatThrownBy(() -> ConnectorIdentity.from(environment))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("APP_NAME=source-kafka but this is the source-database image");
    }

    @Test
    void everyStageOfThePlatformIsAnEnv() {
        for (String env : new String[] {"us-dev", "us-qa", "jp-uat", "us-prod", "us-parallel"}) {
            assertThat(new ConnectorIdentity(env, "cash", "source-database", "trades").env()).isEqualTo(env);
        }
    }

    @Test
    void theVocabularyIsTheGeneratedResourceOfPlatformYml() {
        ConnectorIdentity.Vocabulary vocabulary = ConnectorIdentity.Vocabulary.current();

        assertThat(vocabulary.stages()).contains("dev");
        assertThat(ConnectorIdentity.Vocabulary.load(getClass().getClassLoader())).isEqualTo(vocabulary);
        assertThatThrownBy(() -> ConnectorIdentity.Vocabulary.load(new ClassLoader(null) { }))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("META-INF/platform/identity.properties is not on the classpath");
        Properties withoutFlows = new Properties();
        withoutFlows.setProperty("regions", "us");
        withoutFlows.setProperty("stages", "dev");
        assertThatThrownBy(() -> ConnectorIdentity.Vocabulary.of(withoutFlows, "identity.properties"))
                .hasMessageContaining("identity.properties: flows is empty");
    }

    @Test
    void rejectsTokensOutsideTheNamingModel() {
        assertThatThrownBy(() -> new ConnectorIdentity("us-stage", "cash", "source-database", "trades"))
                .hasMessageContaining("APP_ENV='us-stage' must be local or <region>-<stage>")
                .hasMessageContaining("(platform.yml)");
        assertThatThrownBy(() -> new ConnectorIdentity("xx-dev", "cash", "source-database", "trades"))
                .hasMessageContaining("APP_ENV='xx-dev'");
        assertThatThrownBy(() -> new ConnectorIdentity("us", "cash", "source-database", "trades"))
                .hasMessageContaining("APP_ENV='us'");
        assertThatThrownBy(() -> new ConnectorIdentity("us-dev", "fx", "source-database", "trades"))
                .hasMessageContaining("APP_FLOW");
        assertThatThrownBy(() -> new ConnectorIdentity("us-dev", "cash", "Source_Database", "trades"))
                .hasMessageContaining("APP_NAME");
        assertThatThrownBy(() -> new ConnectorIdentity("us-dev", "cash", "source-database", "42"))
                .hasMessageContaining("never a bare number");
        assertThatThrownBy(() -> new ConnectorIdentity("us-dev", "cash", "source-database", "a".repeat(33)))
                .hasMessageContaining("APP_INSTANCE");
        assertThatThrownBy(() -> new ConnectorIdentity("us-dev", "none", "source-database", "trades"))
                .as("the unset marker is only accepted in local").hasMessageContaining("APP_FLOW");
    }
}
