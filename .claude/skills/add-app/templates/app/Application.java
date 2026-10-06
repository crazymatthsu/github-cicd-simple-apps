package __APP_PACKAGE__;

import org.springframework.boot.autoconfigure.SpringBootApplication;

import com.example.connectors.framework.PlatformApplication;

/**
 * __APP_NAME__: __APP_SUMMARY__. On start-up it logs its identity and the masked effective configuration (the runtime
 * module) and serves the actuator on 8080; {@code --print-config} prints the configuration and exits.
 */
@SpringBootApplication
public class __APP_CLASS__Application {

    public static void main(String[] args) {
        PlatformApplication.run(__APP_CLASS__Application.class, args);
    }
}
