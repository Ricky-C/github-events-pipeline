# The call-site half of the logging contract. JsonLogFormatter (lib/) owns
# the line shape and neutralizes hostile bytes; this mixin owns what every
# entry must carry — component and event — so no call site can forget them
# and no service re-implements the stamping (D-027).
module StructuredLogging
  def self.included(base)
    base.class_attribute :log_component, instance_writer: false
  end

  private

  # An injected @logger wins so services keep their constructor seam for
  # specs; classes without one (GithubClient, jobs) fall back to the app
  # logger.
  def log_event(level, event, **fields)
    logger = @logger || Rails.logger
    logger.public_send(level, { component: log_component, event: event }.merge(fields))
  end
end
