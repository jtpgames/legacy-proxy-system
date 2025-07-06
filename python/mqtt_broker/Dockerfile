FROM eclipse-mosquitto:latest

# Copy custom config file
COPY mosquitto.conf /mosquitto/config/mosquitto.conf

# Expose MQTT port
EXPOSE 1883

# Set user to run mosquitto
USER mosquitto

# Start Mosquitto
CMD ["/usr/sbin/mosquitto", "-c", "/mosquitto/config/mosquitto.conf"]

