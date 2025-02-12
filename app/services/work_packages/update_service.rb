#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2012-2022 the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

# TODO: use default update base class
class WorkPackages::UpdateService < ::BaseServices::BaseCallable
  include ::WorkPackages::Shared::UpdateAncestors
  include ::Shared::ServiceContext

  attr_accessor :user,
                :model,
                :contract_class

  def initialize(user:, model:, contract_class: WorkPackages::UpdateContract)
    self.user = user
    self.model = model
    self.contract_class = contract_class
  end

  def perform(send_notifications: true, **attributes)
    in_context(model, send_notifications) do
      update(attributes)
    end
  end

  private

  def update(attributes)
    result = set_attributes(attributes)

    if result.success?
      work_package.attachments = work_package.attachments_replacements if work_package.attachments_replacements
      result.merge!(update_dependent)
    end

    if save_if_valid(result)
      update_ancestors([work_package]).each do |ancestor_result|
        result.merge!(ancestor_result)
      end
    end

    result
  end

  def save_if_valid(result)
    if result.success?
      result.success = consolidated_results(result)
                       .all?(&:save)
    end

    result.success?
  end

  def update_dependent
    result = ServiceResult.new(success: true, result: work_package)

    result.merge!(update_descendants)

    cleanup if result.success?

    result.merge!(reschedule_related)

    result
  end

  def set_attributes(attributes, wp = work_package)
    WorkPackages::SetAttributesService
      .new(user: user,
           model: wp,
           contract_class: contract_class)
      .call(attributes)
  end

  def update_descendants
    result = ServiceResult.new(success: true, result: work_package)

    if work_package.project_id_changed?
      attributes = { project: work_package.project }

      work_package.descendants.each do |descendant|
        result.add_dependent!(set_attributes(attributes, descendant))
      end
    end

    result
  end

  def cleanup
    if work_package.project_id_changed?
      moved_work_packages = [work_package] + work_package.descendants
      delete_relations(moved_work_packages)
      move_time_entries(moved_work_packages, work_package.project_id)
    end
    if work_package.type_id_changed?
      reset_custom_values
    end
  end

  def delete_relations(work_packages)
    unless Setting.cross_project_work_package_relations?
      Relation
        .of_work_package(work_packages)
        .destroy_all
    end
  end

  def move_time_entries(work_packages, project_id)
    TimeEntry
      .on_work_packages(work_packages)
      .update_all(project_id: project_id)
  end

  def reset_custom_values
    work_package.reset_custom_values!
  end

  def reschedule_related
    result = ServiceResult.new(success: true, result: work_package)

    with_temporarily_persisted_parent_changes do
      if work_package.parent_id_changed? && work_package.parent_id_was
        result.merge!(reschedule_former_siblings)
      end

      result.merge!(reschedule(work_package))
    end

    result
  end

  def with_temporarily_persisted_parent_changes
    # Explicitly using requires_new: true since we are already within a transaction.
    # Because of that, raising ActiveRecord::Rollback would have no effect:
    # https://www.bigbinary.com/learn-rubyonrails-book/activerecord-transactions-in-depth#nested-transactions
    WorkPackage.transaction(requires_new: true) do
      if work_package.parent_id_changed?
        # HACK: we need to persist the parent relation before rescheduling the parent
        # and the former parent since we rely on the database for scheduling.
        # The following will update the parent_id of the work package without that being noticed by the
        # work package instance (work_package) that is already instantiated. That way, the change can be rolled
        # back without any side effects to the instance (e.g. dirty tracking).
        WorkPackage.where(id: work_package.id).update_all(parent_id: work_package.parent_id)
        work_package.rebuild! # using the ClosureTree#rebuild! method to update the transitive hierarchy information
      end

      yield

      # Always rolling back the changes we made in here
      raise ActiveRecord::Rollback
    end
  end

  # Rescheduling the former siblings will lead to the whole former tree being rescheduled.
  def reschedule_former_siblings
    reschedule(WorkPackage.where(parent_id: work_package.parent_id_was))
  end

  def reschedule(work_packages)
    WorkPackages::SetScheduleService
      .new(user: user,
           work_package: work_packages)
      .call(changed_attributes)
  end

  def changed_attributes
    work_package.changed.map(&:to_sym)
  end

  # When multiple services change a work package, we still only want one update to the database due to:
  # * performance
  # * having only one journal entry
  # * stale object errors
  # we thus consolidate the results so that one instance contains the changes made by all the services.
  def consolidated_results(result)
    result.all_results.group_by(&:id).inject([]) do |a, (_, instances)|
      master = instances.pop

      instances.each do |instance|
        master.attributes = instance.changes.transform_values(&:last)
      end

      a + [master]
    end
  end

  def work_package
    model
  end
end
