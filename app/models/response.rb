class Response < ActiveRecord::Base
  include ActionView::Helpers::SanitizeHelper
  include Surveyor::Models::ResponseMethods

  def requirement_level
    @requirement_level ||= answer.requirement_level
  end

  def requirement
    @requirement ||= answer.requirement
  end

  def requirement_level_index
    @requirement_level_index ||= Survey::REQUIREMENT_LEVELS.index(requirement_level)
  end

  def ui_hash_values
    [:datetime_value, :integer_value, :float_value, :unit, :text_value, :string_value, :response_other].reduce({}) do |memo, key|
      value = self.send(key)
      memo[key] = value unless value.blank?
      memo
    end
  end

end