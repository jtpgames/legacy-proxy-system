package com.jl;

import com.hivemq.extension.sdk.api.ExtensionMain;
import com.hivemq.extension.sdk.api.annotations.NotNull;
import com.hivemq.extension.sdk.api.interceptor.publish.PublishOutboundInterceptor;
import com.hivemq.extension.sdk.api.interceptor.publish.parameter.PublishOutboundInput;
import com.hivemq.extension.sdk.api.interceptor.publish.parameter.PublishOutboundOutput;
import com.hivemq.extension.sdk.api.interceptor.publish.PublishInboundInterceptor;
import com.hivemq.extension.sdk.api.interceptor.publish.parameter.PublishInboundInput;
import com.hivemq.extension.sdk.api.interceptor.publish.parameter.PublishInboundOutput;
import com.hivemq.extension.sdk.api.parameter.ExtensionStartInput;
import com.hivemq.extension.sdk.api.parameter.ExtensionStartOutput;
import com.hivemq.extension.sdk.api.parameter.ExtensionStopInput;
import com.hivemq.extension.sdk.api.parameter.ExtensionStopOutput;
import com.hivemq.extension.sdk.api.services.Services;
import com.hivemq.extension.sdk.api.services.publish.Publish;
import com.hivemq.extension.sdk.api.services.publish.PublishService;
import com.hivemq.extension.sdk.api.services.intializer.InitializerRegistry;
import com.hivemq.extension.sdk.api.packets.publish.PublishPacket;
import com.hivemq.extension.sdk.api.packets.general.UserProperties;
import com.hivemq.extension.sdk.api.services.builder.Builders;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ConcurrentHashMap;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class RetryPriorityExtension implements ExtensionMain 
{
    private static final Logger log = LoggerFactory.getLogger(RetryPriorityExtension.class);
    private static final AtomicInteger pendingRetries = new AtomicInteger(0);
    private static final ConcurrentHashMap<Long, ScheduledFuture<?>> scheduledTasks = new ConcurrentHashMap<>();
    private static final AtomicInteger taskIdCounter = new AtomicInteger(0);

    @Override
    public void extensionStart(@NotNull ExtensionStartInput input, @NotNull ExtensionStartOutput output) 
    {
        log.info("[RETRY-PRIORITY] Extension starting - initializing interceptors");
        
        final InitializerRegistry initializerRegistry = Services.initializerRegistry();

        initializerRegistry.setClientInitializer((initializerInput, clientContext) -> {
            clientContext.addPublishInboundInterceptor(new RetryInboundInterceptor());
            clientContext.addPublishOutboundInterceptor(new RetryOutboundInterceptor());
        });
    }

    @Override
    public void extensionStop(@NotNull ExtensionStopInput input, @NotNull ExtensionStopOutput output)
    {
        // Cancel all pending scheduled tasks
        scheduledTasks.values().forEach(task -> task.cancel(false));
        scheduledTasks.clear();
        pendingRetries.set(0);
    }

    static class RetryInboundInterceptor implements PublishInboundInterceptor 
    {
        @Override
        public void onInboundPublish(@NotNull PublishInboundInput input, @NotNull PublishInboundOutput output)
        {
            String topic = input.getPublishPacket().getTopic();

            boolean isRetry = isRetryTopic(topic);
            int pendingCount = pendingRetries.get();
            // Extract message content for debugging
            String messageContent = "";
            if (input.getPublishPacket().getPayload().isPresent()) {
                ByteBuffer payload = input.getPublishPacket().getPayload().get();
                byte[] bytes = new byte[payload.remaining()];
                payload.get(bytes);
                payload.rewind(); // Reset position for later use
                messageContent = new String(bytes, StandardCharsets.UTF_8);
            }

            log.info("[INBOUND] Topic: {}, Message: {}, IsRetry: {}, PendingRetries: {}, QoS: {}", 
                topic, messageContent, isRetry, pendingCount, input.getPublishPacket().getQos());

            if (isRetryTopic(topic))
            {
                pendingRetries.incrementAndGet();
            }
        }
    }

    static class RetryOutboundInterceptor implements PublishOutboundInterceptor 
    {
        private static final Logger log = LoggerFactory.getLogger(RetryOutboundInterceptor.class);
        
        @Override
        public void onOutboundPublish(@NotNull PublishOutboundInput input, @NotNull PublishOutboundOutput output)
        {
            String topic = input.getPublishPacket().getTopic();
            
            // Extract message content for debugging
            String messageContent = "";
            if (input.getPublishPacket().getPayload().isPresent()) {
                ByteBuffer payload = input.getPublishPacket().getPayload().get();
                byte[] bytes = new byte[payload.remaining()];
                payload.get(bytes);
                payload.rewind(); // Reset position for later use
                messageContent = new String(bytes, StandardCharsets.UTF_8);
            }
            
            boolean isRetry = isRetryTopic(topic);
            int pendingCount = pendingRetries.get();
            
            log.info("[OUTBOUND] Topic: {}, Message: {}, IsRetry: {}, PendingRetries: {}, QoS: {}", 
                     topic, messageContent, isRetry, pendingCount, input.getPublishPacket().getQos());

            // If retries are pending and this is NOT a retry message, delay it
            if (pendingRetries.get() > 0 && !isRetryTopic(topic))
            {
                log.info("[OUTBOUND] Delaying normal message: {}", messageContent);
                try {
                    output.preventPublishDelivery();
                } catch (Exception e) {
                    log.info("[OUTBOUND] Exception in preventPublishDelivery: {}", e);
                }
                log.info("[OUTBOUND] After preventPublishDelivery for message: {}", messageContent);

                PublishService publishService = Services.publishService();
                PublishPacket packet = input.getPublishPacket();
                
                // Preserve all message properties
                Publish original = Builders.publish()
                        .topic(topic)
                        .qos(packet.getQos())
                        .retain(packet.getRetain())
                        .payload(packet.getPayload().orElse(null))
                        .build();
                
                // Track scheduled task for cleanup
                long taskId = taskIdCounter.getAndIncrement();
                ScheduledFuture<?> future = Services.extensionExecutorService().schedule(() -> {
                    log.info("[OUTBOUND] Trying to redeliver. taskId: {}", taskId);
                    scheduledTasks.remove(taskId);
                    // Only publish if no retries are pending anymore
                    if (pendingRetries.get() == 0) 
                    {
                        publishService.publish(original);
                    } else
                    {
                        // Re-schedule if still blocked
                        onOutboundPublish(input, output);
                    }
                }, 2, TimeUnit.SECONDS);
                
                scheduledTasks.put(taskId, future);
                log.info("[OUTBOUND] Redelivery scheduled. taskId: {}, message: {}", taskId, messageContent);
            }

            // If this IS a retry message going out, decrement counter
            if (isRetryTopic(topic))
            {
                int newCount = pendingRetries.decrementAndGet();
                log.info("[OUTBOUND] Retry message delivered: {}, Remaining retries: {}", messageContent, newCount);
            }
        }
    }

    /**
     * Check if a topic contains a 'retry' level in its path.
     * Examples: "service1/retry/message", "retry/message", "app/retry/data" all match
     */
    private static boolean isRetryTopic(String topic) {
        String[] levels = topic.split("/");
        for (String level : levels) {
            if ("retry".equals(level)) {
                return true;
            }
        }
        return false;
    }
}

