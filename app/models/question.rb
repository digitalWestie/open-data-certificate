class Question < ActiveRecord::Base
  # Mustache
  include Surveyor::MustacheContext

  belongs_to :survey_section, :inverse_of => :questions
  belongs_to :question_group, :dependent => :destroy
  has_many :answers, :dependent => :destroy, :inverse_of => :question # it might not always have answers
  has_one :dependency, :dependent => :destroy
  belongs_to :correct_answer, :class_name => "Answer", :dependent => :destroy

  # Scopes
  default_scope :order => "#{quoted_table_name}.display_order ASC"

  # Validations
  validates_presence_of :text, :display_order
  validates_inclusion_of :is_mandatory, :in => [true, false]

  # Whitelisting attributes
  attr_accessible :survey_section, :question_group, :survey_section_id, :question_group_id, :text, :short_text, :help_text, :pick, :reference_identifier, :data_export_identifier, :common_namespace, :common_identifier, :display_order, :display_type, :is_mandatory, :display_width, :custom_class, :custom_renderer, :correct_answer_id, :requirement, :required, :help_text_more_url, :text_as_statement, :display_on_certificate, :discussion_topic

  scope :excluding, lambda { |*objects| where(['questions.id NOT IN (?)', (objects.flatten.compact << 0)]) }
  scope :mandatory, where(is_mandatory: true)
  scope :urls, joins(:answers).merge(Answer.urls)

  scope :for_id, lambda { |id| where(reference_identifier: id) }

  before_save :cache_question_or_answer_corresponding_to_requirement
  before_save :set_default_value_for_required
  before_save :set_mandatory

  belongs_to :question_corresponding_to_requirement, :class_name => "Question"
  belongs_to :answer_corresponding_to_requirement, :class_name => "Answer"
  has_one :survey, :through => :survey_section, :inverse_of => :questions
  has_many :responses, :inverse_of => :question

  def initialize(*args)
    super(*args)
    self.is_mandatory ||= false
    self.display_type ||= "default"
    self.pick ||= "none"
    self.data_export_identifier ||= Surveyor::Common.normalize(text)
    self.short_text ||= text
    self.api_id ||= Surveyor::Common.generate_api_id
  end

  def pick=(val)
    write_attribute(:pick, val.nil? ? nil : val.to_s)
  end
  def display_type=(val)
    write_attribute(:display_type, val.nil? ? nil : val.to_s)
  end

  def mandatory?
    self.is_mandatory == true
  end

  def part_of_group?
    !self.question_group.nil?
  end

  def solo?
    self.question_group.nil?
  end

  def text_for(position = nil, context = nil, locale = nil)
    return "" if display_type == "hidden_label"
    imaged(split(in_context(translation(locale)[:text], context), position))
  end

  def help_text_for(context = nil, locale = nil)
    in_context(translation(locale)[:help_text], context)
  end

  def split(text, position=nil)
    case position
    when :pre
      text.split("|",2)[0]
    when :post
      text.split("|",2)[1]
    else
      text
    end.to_s
  end

  def renderer(g = question_group)
    r = [g ? g.renderer.to_s : nil, display_type].compact.join("_")
    r.blank? ? :default : r.to_sym
  end

  # either provided text_as_statement, or fall back to text
  def statement_text(locale=I18n.locale)
    translation(locale)[:text_as_statement] || text
  end

  def requirement_level
    # Definition: The level to which the current question is assigned. This is used to determine the level for achieved
    #             and outstanding requirements, and for the display customisation of questions.
    #TODO: Create an association to a model for Improvements? Or just leave it as a text key for the translations?
    @requirement_level ||= requirement.to_s.match(/^[a-zA-Z]*/).to_s
  end

  def minimum_level
    case required
    when '', nil
      nil
    when "required"
      "basic"
    when String
      required
    end
  end

  def requirement_level_index
    @requirement_level_index ||= Survey::REQUIREMENT_LEVELS.index(requirement_level) || 0
  end

  def is_a_requirement?
    # Definition: A 'Requirement' is a bar that needs to be passed to contribute to attaining a certain level in the questionnaire.
    #             This is not the same as being "required" - which is about whether a question is mandatory to be completed.
    #             For the moment, requirements are stored in the DB as labels with a 'requirement' attribute set.
    @is_a_requirement ||= display_type == 'label' && !requirement.blank?
  end

  def requirement_met_by_responses?(responses)
    # could use thusly to get all the displayed requirements for a survey and whether they have been met by their corresponding answers:
    #   `response_set.survey.questions.flatten.select{|e|e.is_a_requirement? && e.triggered?(response_set)}.map{|e|[e.requirement, e.requirement_met_by_responses?(rs.responses)]}`
    @requirement_met_by_responses ||= calculate_if_requirement_met_by_responses(responses)
  end

  def dependent?
    @dependent_q ||= self.dependency(includes: :dependency_conditions) != nil
  end

  def metadata_field?
    @metadata_field ||= survey_section.survey.metadata_fields.include?(reference_identifier)
  end

  def triggered?(response_set)
    dep_map = response_set.depends
    @triggered_q ||= dependency.nil? || dep_map[dependency.id]
  end

  def is_mandatory?
    required.to_s == "required"
  end

  def type
    @type ||= question_group && question_group.display_type == 'repeater' ? :repeater : pick.to_sym
  end

  def answer(identifier)
    if answers.loaded?
      answers.find{|a| a.reference_identifier == identifier }
    else
      answers.for_id(identifier).first
    end
  end

  def translation(locale)
    case(display_type)
    when 'label'
      survey.translation(locale).fetch(:labels, {})[reference_identifier] || {}
    else
      {:text => self.text, :help_text => self.help_text}.with_indifferent_access.merge(
        (self.survey_section.survey.translation(locale)[:questions] || {})[self.reference_identifier] || {}
      )
    end
  end

  def heading(locale=I18n.locale)
    translation(locale)[:text] || text
  end

  def subheading(locale=I18n.locale)
    translation(locale)[:help_text] || help_text
  end

  def placeholder(locale=I18n.locale)
    if a = answer("1")
      a.translation(locale)[:placeholder] || a.placeholder
    end
  end

  def css_class(response_set)
    triggered = triggered?(response_set) || (part_of_group? && question_group.dependent?)
    [(dependent? ? "q_dependent" : nil), (triggered ? nil : "q_hidden"), custom_class].compact.join(" ")
  end

  def choice_type?
    %w[one any].include?(pick)
  end


  private


  def imaged(text)
    self.display_type == "image" && !text.blank? ? ActionController::Base.helpers.image_tag(text) : text
  end

  def calculate_if_requirement_met_by_responses(responses)
    # NOTE: At the moment, there is an expectation that each requirement is associated to only one question or answer in
    #       a survey
    #       If a requirement is tied to more that one question or answer, then the calculation of whether it's met needs
    #       to be more comprehensive - it would have to ensure that *every* occurrence of the requirement has been met to
    #       definitively say the requirement has been met.
    #       Validation in the Survey model is used to prevent a requirement getting linked to more than one question or answer
    question = answer_corresponding_to_requirement.try(:question) || question_corresponding_to_requirement

    return false unless question # if for some reason a matching question is not found

    !!(response_level_index(question, responses) >= requirement_level_index)
  end

  def response_level_index(question, responses)
    if question.pick == 'one'
      max_level_for_responses(question.id, responses)
    else
      requirement_level_for_responses(question.id, responses)
    end
  end

  def max_level_for_responses(question_id, responses)
    responses.where(:question_id => question_id).map(&:requirement_level_index).max.to_i
  end

  def requirement_level_for_responses(question_id, responses)
    responses.joins(:answer).where(["responses.question_id = ? AND answers.requirement = ?", question_id, requirement])
                            .first
                            .try(:requirement_level_index)
                            .to_i
  end

  def set_mandatory
    self.is_mandatory ||= is_mandatory?
    nil # return value of false prevents saving
  end

  def set_default_value_for_required
    self.required ||= '' # don't let requirement be nil, as we're querying the DB for it in the Survey, so it needs to be an empty string if nothing
  end

  def corresponds_to_requirement?(subject, requirement)
    subject.requirement && requirement && subject.requirement.include?(requirement)
  end

  def calculate_question_corresponding_to_requirement
    get_questions.detect { |q| corresponds_to_requirement?(q, requirement) }
  end

  def calculate_answer_corresponding_to_requirement
    get_answers.detect { |a| corresponds_to_requirement?(a, requirement) }
  end

  def get_answers
    survey_section.survey.only_questions.map(&:answers).flatten
  end

  def get_questions
    survey_section.survey.only_questions
  end

  def cache_question_or_answer_corresponding_to_requirement
    if survey_section && is_a_requirement?
      self.question_corresponding_to_requirement ||= calculate_question_corresponding_to_requirement

      unless self.question_corresponding_to_requirement
        self.answer_corresponding_to_requirement ||= calculate_answer_corresponding_to_requirement
      end
    end
  end

end
