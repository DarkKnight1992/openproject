require_dependency "entry"
require 'forwardable'

class CostQuery < ActiveRecord::Base
  extend Forwardable
  #belongs_to :user
  #belongs_to :project
  #attr_protected :user_id, :project_id, :created_at, :updated_at

  def self.accepted_properties
    @accepted_properties ||= []
  end

  # FIXME: (RE)MOVE ME
  def self.example
    @example ||= CostQuery.new.group_by(:issue_id).column(:tweek).row(:project_id).row(:user_id)
  end

  def walker
    @walker ||= CostQuery::Walker.new self
  end

  def add_chain(type, name, options)
    chain type.const_get(name.to_s.camelcase), options
    self
  end

  def chain(klass = nil, options = {})
    @walker = nil
    @chain ||= Filter::NoFilter.new
    @chain = klass.new @chain, options if klass
    @chain = @chain.parent until @chain.top?
    @chain
  end

  def filter(name, options = {})
    add_chain Filter, name, options
  end

  def group_by(name, options = {})
    add_chain GroupBy, name, options.reverse_merge(:type => :column)
  end

  def column(name, options = {})
    group_by name, options.merge(:type => :column)
  end

  def row(name, options = {})
    group_by name, options.merge(:type => :row)
  end

  def_delegators :walker, :walk, :column_first, :row_first
  def_delegators :chain, :result, :top, :bottom, :chain_collect, :sql_statement, :all_group_fields

end;
