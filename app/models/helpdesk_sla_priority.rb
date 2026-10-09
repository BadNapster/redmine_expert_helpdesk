# SLA target times per priority (override of the project defaults).
# Empty minute values mean: the project default applies.
class HelpdeskSlaPriority < HelpdeskApplicationRecord
  belongs_to :project
  belongs_to :priority, :class_name => 'IssuePriority'

  validates :project_id,  :presence => true
  validates :priority_id, :presence => true, :uniqueness => { :scope => :project_id }
  validates :reaction_minutes, :solution_minutes,
            :numericality => { :only_integer => true, :greater_than => 0 }, :allow_nil => true
end
