# Shared (abstract) base class of the plugin models.
#
# Redmine 6+ defines `ApplicationRecord` and mixes the `acts_as_*` DSLs in there;
# Redmine 5.x does not know `ApplicationRecord` and mixes them into
# `ActiveRecord::Base`. So pick the right base per version, so the models get
# `acts_as_event`, `acts_as_activity_provider`, `acts_as_positioned` etc. under
# both versions.
class HelpdeskApplicationRecord < (defined?(ApplicationRecord) ? ApplicationRecord : ActiveRecord::Base)
  self.abstract_class = true
end
