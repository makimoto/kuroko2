class JobDefinition < ActiveRecord::Base
  module PreventMultiStatus
    NONE = 0
    WORKING_OR_ERROR = 1
    WORKING = 2
    ERROR = 3
  end

  PREVENT_TOKEN_STATUSES = {
    PreventMultiStatus::NONE => [],
    PreventMultiStatus::WORKING_OR_ERROR => [
      Token::WORKING,
      Token::FAILURE,
      Token::CRITICAL
    ],
    PreventMultiStatus::WORKING => [Token::WORKING],
    PreventMultiStatus::ERROR => [Token::FAILURE, Token::CRITICAL],
  }

  self.locking_column = :version

  paginates_per 100

  has_many :admin_assignments, dependent: :destroy
  has_many :admins, -> { active }, through: :admin_assignments, source: :user
  has_many :job_instances, -> { order(:id).reverse_order } do
    def any_token?
      self.any? do |instance|
        instance.tokens.present?
      end
    end
  end
  has_many :job_schedules, dependent: :delete_all
  has_many :job_suspend_schedules, dependent: :delete_all
  has_many :job_definition_tags
  has_many :tags, through: :job_definition_tags
  has_one :memory_expectancy, dependent: :destroy

  before_destroy :confirm_active_instances
  after_initialize :set_default_values
  after_save :create_default_memory_expectancy, on: :create

  scope :ordered, -> { order(:id) }
  scope :tagged_by, ->(tags) {
    where(
      id: JobDefinitionTag.
        where(tag_id: Tag.where(name: tags).pluck(:id)).
        group(:job_definition_id).
        having('COUNT(1) >= ?', tags.size).
        pluck(:job_definition_id)
    )
  }
  scope :search_by, ->(query) {
    column = arel_table
    or_query = column[:name].matches("%#{query}%").or(column[:script].matches("%#{query}%"))

    search_by_tag_definition_ids = JobDefinitionTag.joins(:tag).
      where('tags.name LIKE ?', "%#{query}%").distinct.pluck(:job_definition_id)

    if search_by_tag_definition_ids.present?
      or_query = or_query.or(column[:id].in(search_by_tag_definition_ids))
    end

    where(or_query)
  }


  validates :name, length: { maximum: 40 }, presence: true
  validates :description, presence: true
  validates :script, presence: true
  validate :script_syntax
  validate :validate_number_of_admins
  validates :hipchat_additional_text, length: { maximum: 180 }
  validates :slack_channel, length: { maximum: 21 }, format: {
    with: /\A#[^\.\s]+\z/, allow_blank: true,
    message: ' must start with # and must not include any dots or spaces'
  }

  def proceed_multi_instance?
    tokens = Token.where(job_definition_id: self.id)
    (tokens.map(&:status) & PREVENT_TOKEN_STATUSES[self.prevent_multi]).empty?
  end

  def text_tags
    tags.pluck(:name).join(',')
  end

  def text_tags=(text_tags)
    self.tags = text_tags.gsub(/[[:blank:]]+/, '').split(/[,、]/).uniq.map do |name|
      Tag.find_or_create_by(name: name)
    end
  end

  private

  def confirm_active_instances
    if job_instances.any_token?
      errors.add(:base, I18n.t('model.job_definition.confirm_active_instances'))

      false
    else
      true
    end
  end

  def set_default_values
    self.description ||= <<-EOF.strip_heredoc
      An description of the job definition.

      ## Failure Affects
      Affected users, services and/ or business areas.

      ## Workaround
      Choose one of the following:
      - __Retry__ as soon as possible.
      - Make an urgent call to administrator (Job stays in _Error_ state)
      - Do nothing, and let administrator recover later (Job stays in _Error_ state)
      - Ignore error and _Cancel_ the job (No recovery required)

      ## Recovery Procedures
      Describe how to recover from the failure.
    EOF
  end

  def create_default_memory_expectancy
    create_memory_expectancy! unless memory_expectancy
  end

  def script_syntax
    Workflow::ScriptParser.new(script).parse

    true
  rescue Workflow::SyntaxError => e
    errors.add(:base, I18n.t('model.job_definition.script_syntax', reason: e.message))

    false
  rescue Workflow::AssertionError => e
    errors.add(:base, I18n.t('model.job_definition.validation_error', reason: e.message))

    false
  end

  def validate_number_of_admins
    if self.admins.empty?
      errors.add(:admins, I18n.t('model.job_definition.validate_number_of_admins'))
    end
  end
end