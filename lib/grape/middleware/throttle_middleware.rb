module Grape
  module Middleware
    class ThrottleMiddleware < Grape::Middleware::Base
      def before
        endpoint = env['api.endpoint']
        logger   = options[:logger] || Logger.new(STDOUT)
        return unless throttle_options = endpoint.route_setting(:throttle)

        if endpoint.header.nil?
          endpoint.instance_variable_set :@header, {}
        end

        if limit = throttle_options[:hourly]
          period = 1.hour
        elsif limit = throttle_options[:daily]
          period = 1.day
        elsif limit = throttle_options[:monthly]
          period = 1.month
        elsif period = throttle_options[:period]
          limit = throttle_options[:limit]
        end
        if limit.nil? || period.nil?
          raise ArgumentError.new('Please set a period and limit (see documentation)')
        end

        user_key = options[:user_key]
        user_value = nil
        user_value = user_key.call(env) unless user_key.nil?
        user_value ||= "ip:#{env['REMOTE_ADDR']}"

        r = endpoint.routes.first
        rate_key = "#{r.route_method}:#{r.route_path}:#{user_value}"

        redis = options[:cache]
        begin
          redis.ping
          current = redis.get(rate_key).to_i

          # X-Throttle-Remaining: int RemainingRequests
          if !options[:remaining_header].nil?
            header_key = if options[:remaining_header].is_a? String
              options[:remaining_header]
            else
              "X-Throttle-Remaining"
            end

            endpoint.header header_key, [0, limit - current].max
          end

          # X-Throttle-Limit: int MaxRequests
          if !options[:limit_header].nil?
            header_key = if options[:limit_header].is_a? String
              options[:limit_header]
            else
              "X-Throttle-Limit"
            end

            endpoint.header header_key, limit
          end

          # X-Throttle-Reset: int Epoch
          if !options[:expires_header].nil?
            header_key = if options[:expires_header].is_a? String
              options[:expires_header]
            else
              "X-Throttle-Reset"
            end

            ttl = redis.ttl(rate_key).to_i
            if ttl < 0 # -2 = expired, -1 = no TTL
              ttl = period.to_i
            end

            endpoint.header header_key, Time.now + ttl
          end

          if env["REQUEST_METHOD"] != "HEAD"
            if !current.nil? && current >= limit
              endpoint.error!("too many requests, please try again later", 403)
            else
              redis.multi do
                redis.incr(rate_key)

                # Push expiry forward in slots, not every request.
                if options[:coast_expiry].nil? or !options[:coast_expiry] or current.nil? or current == 0
                  redis.expire(rate_key, period.to_i)
                end
              end
            end
          end

        rescue Exception => e
          logger.warn(e.message)
        end

      end

    end
  end
end
