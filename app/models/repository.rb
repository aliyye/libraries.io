class Repository < ApplicationRecord
  include RepoSearch
  include Status
  include RepoManifests
  include RepositorySourceRank

  STATUSES = ['Active', 'Deprecated', 'Unmaintained', 'Help Wanted', 'Removed']

  API_FIELDS = [:full_name, :description, :fork, :created_at, :updated_at, :pushed_at, :homepage,
   :size, :stargazers_count, :language, :has_issues, :has_wiki, :has_pages,
   :forks_count, :mirror_url, :open_issues_count, :default_branch,
   :subscribers_count, :private, :logo_url, :pull_requests_enabled, :scm]

  has_many :projects
  has_many :contributions, dependent: :delete_all
  has_many :contributors, through: :contributions, source: :github_user
  has_many :tags, dependent: :delete_all
  has_many :published_tags, -> { published }, anonymous_class: Tag
  has_many :manifests, dependent: :destroy
  has_many :dependencies, through: :manifests, source: :repository_dependencies
  has_many :dependency_projects, -> { group('projects.id').order("COUNT(projects.id) DESC") }, through: :dependencies, source: :project
  has_many :dependency_repos, -> { group('repositories.id') }, through: :dependency_projects, source: :repository

  has_many :repository_subscriptions, dependent: :delete_all
  has_many :web_hooks, dependent: :delete_all
  has_many :issues, dependent: :delete_all
  has_one :readme, dependent: :delete
  belongs_to :github_organisation
  belongs_to :github_user, primary_key: :github_id, foreign_key: :owner_id
  belongs_to :source, primary_key: :full_name, foreign_key: :source_name, anonymous_class: Repository
  has_many :forked_repositories, primary_key: :full_name, foreign_key: :source_name, anonymous_class: Repository

  validates :full_name, uniqueness: true, if: lambda { self.full_name_changed? }
  validates :uuid, uniqueness: true, if: lambda { self.uuid_changed? }

  before_save  :normalize_license_and_language
  after_commit :update_all_info_async, on: :create
  after_commit :save_projects, on: :update
  after_commit :update_source_rank_async

  scope :without_readme, -> { where("repositories.id NOT IN (SELECT repository_id FROM readmes)") }
  scope :with_projects, -> { joins(:projects) }
  scope :without_projects, -> { includes(:projects).where(projects: { repository_id: nil }) }
  scope :without_subscriptons, -> { includes(:repository_subscriptions).where(repository_subscriptions: { repository_id: nil }) }
  scope :with_tags, -> { joins(:tags) }
  scope :without_tags, -> { includes(:tags).where(tags: { repository_id: nil }) }

  scope :host, lambda{ |host_type| where('lower(repositories.host_type) = ?', host_type.try(:downcase)) }

  scope :fork, -> { where(fork: true) }
  scope :source, -> { where(fork: false) }

  scope :open_source, -> { where(private: false) }
  scope :from_org, lambda{ |org_id|  where(github_organisation_id: org_id) }

  scope :with_manifests, -> { joins(:manifests) }
  scope :without_manifests, -> { includes(:manifests).where(manifests: {repository_id: nil}) }

  scope :with_description, -> { where("repositories.description <> ''") }
  scope :with_license, -> { where("repositories.license <> ''") }
  scope :without_license, -> {where("repositories.license IS ? OR repositories.license = ''", nil)}

  scope :pushed, -> { where.not(pushed_at: nil) }
  scope :good_quality, -> { maintained.open_source.pushed }
  scope :with_stars, -> { where('repositories.stargazers_count > 0') }
  scope :interesting, -> { with_stars.order('repositories.stargazers_count DESC, repositories.pushed_at DESC') }
  scope :uninteresting, -> { without_readme.without_manifests.without_license.where('repositories.stargazers_count = 0').where('repositories.forks_count = 0') }

  scope :recently_created, -> { where('created_at > ?', 7.days.ago)}
  scope :hacker_news, -> { order("((stargazers_count-1)/POW((EXTRACT(EPOCH FROM current_timestamp-created_at)/3600)+2,1.8)) DESC") }
  scope :trending, -> { good_quality.recently_created.with_stars }

  scope :maintained, -> { where('repositories."status" not in (?) OR repositories."status" IS NULL', ["Deprecated", "Removed", "Unmaintained"])}
  scope :deprecated, -> { where('repositories."status" = ?', "Deprecated")}
  scope :not_removed, -> { where('repositories."status" != ? OR repositories."status" IS NULL', "Removed")}
  scope :removed, -> { where('repositories."status" = ?', "Removed")}
  scope :unmaintained, -> { where('repositories."status" = ?', "Unmaintained")}

  scope :indexable, -> { open_source.not_removed.includes(:projects, :readme) }

  delegate :download_owner, :download_readme, :domain, :watchers_url, :forks_url,
           :download_fork_source, :download_tags, :download_contributions, :url,
           :create_webhook, :download_issues, :download_forks, :stargazers_url,
           :formatted_host, :get_file_list, :get_file_contents, :issues_url,
           :source_url, :contributors_url, :blob_url, :raw_url, :commits_url, to: :repository_host

  def self.language(language)
    where('lower(repositories.language) = ?', language.try(:downcase))
  end

  def meta_tags
    {
      title: "#{full_name} on #{formatted_host}",
      description: description_with_language,
      image: avatar_url(200)
    }
  end

  def description_with_language
    language_text = [language, "repository"].compact.join(' ').with_indefinite_article
    [description, "#{language_text} on #{formatted_host}"].compact.join(' - ')
  end

  def normalize_license_and_language
    self.language = Languages::Language[self.language].to_s
    self.language = nil if self.language.blank?
    return if license.blank?
    if license.downcase == 'other'
      self.license = 'Other'
    else
      l = Spdx.find(license).try(:id)
      l = 'Other' if l.blank?
      self.license = l
    end
  end

  def deprecate!
    update_attribute(:status, 'Deprecated')
    projects.each do |project|
      project.update_attribute(:status, 'Deprecated')
    end
  end

  def unmaintain!
    update_attribute(:status, 'Unmaintained')
    projects.each do |project|
      project.update_attribute(:status, 'Unmaintained')
    end
  end

  def save_projects
    projects.find_each(&:forced_save)
  end

  def repository_dependencies
    manifests.latest.includes({repository_dependencies: {project: :versions}}).map(&:repository_dependencies).flatten.uniq
  end

  def owner
    return nil unless host_type == 'GitHub'
    github_organisation_id.present? ? github_organisation : github_user
  end

  def to_s
    full_name
  end

  def to_param
    {
      host_type: host_type.downcase,
      owner: owner_name,
      name: project_name
    }
  end

  def owner_name
    full_name.split('/')[0]
  end

  def project_name
    full_name.split('/')[1]
  end

  def color
    Languages::Language[language].try(:color)
  end

  def stars
    stargazers_count || 0
  end

  def forks
    forks_count || 0
  end

  def avatar_url(size = 60)
    avatar = repository_host.avatar_url(size)
    return fallback_avatar_url(size) if avatar.blank?
    avatar
  end

  def fallback_avatar_url(size = 60)
    hash = Digest::MD5.hexdigest("#{host_type}-#{full_name}")
    "https://www.gravatar.com/avatar/#{hash}?s=#{size}&f=y&d=retro"
  end

  def load_dependencies_tree(date = nil)
    RepositoryTreeResolver.new(self, date).load_dependencies_tree
  end

  def id_or_name
    uuid || full_name
  end

  def update_all_info_async(token = nil)
    RepositoryDownloadWorker.perform_async(self.id, token)
  end

  def update_all_info(token = nil)
    token ||= AuthToken.token if host_type == 'GitHub'
    update_from_repository(token)
    download_owner
    download_fork_source(token)
    download_readme(token)
    download_tags(token)
    download_contributions(token)
    download_manifests(token)
    # download_issues(token)
    save_projects
    update_attributes(last_synced_at: Time.now)
  end

  def update_from_repository(token)
    repository_host.update(token)
  end

  def self.create_from_host(host_type, full_name, token = nil)
    RepositoryHost.const_get(host_type.capitalize).create(full_name, token)
  end

  def self.create_from_hash(repo_hash)
    return unless repo_hash
    repo_hash = repo_hash.to_hash.with_indifferent_access
    ActiveRecord::Base.transaction do
      g = Repository.find_by(uuid: repo_hash[:id])
      g = Repository.host(repo_hash[:host_type] || 'GitHub').find_by('lower(full_name) = ?', repo_hash[:full_name].downcase) if g.nil?
      g = Repository.new(uuid: repo_hash[:id], full_name: repo_hash[:full_name]) if g.nil?
      g.owner_id = repo_hash[:owner][:id]
      g.host_type = repo_hash[:host_type] || 'GitHub'
      g.full_name = repo_hash[:full_name] if g.full_name.downcase != repo_hash[:full_name].downcase
      g.uuid = repo_hash[:id] if g.uuid.nil?
      g.license = repo_hash[:license][:key] if repo_hash[:license]
      g.source_name = repo_hash[:parent][:full_name] if repo_hash[:fork] && repo_hash[:parent]
      g.assign_attributes repo_hash.slice(*Repository::API_FIELDS)

      if g.changed?
        return g.save ? g : nil
      else
        return g
      end
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def self.check_status(host_type, repo_full_name, removed = false)
    domain = RepositoryHost::Base.domain(host_type)
    response = Typhoeus.head("#{domain}/#{repo_full_name}")

    if response.response_code == 404
      repo = Repository.includes(:projects).find_by_full_name(repo_full_name)
      if repo
        status = removed ? nil : 'Removed'
        repo.update_attribute(:status, status) if !repo.private?
        repo.projects.each do |project|
          next unless ['bower', 'go', 'elm', 'alcatraz', 'julia', 'nimble'].include?(project.platform.downcase)
          project.update_attribute(:status, status)
        end
      end
    end
  end

  def self.update_from_hook(uuid, sender_id)
    repository = Repository.host('GitHub').find_by_uuid(uuid)
    user = Identity.where('provider ILIKE ?', 'github%').where(uid: sender_id).first.try(:user)
    if user.present? && repository.present?
      repository.download_manifests(user.token)
      repository.update_all_info_async(user.token)
    end
  end

  def self.update_from_star(repo_name, token = nil)
    token ||= AuthToken.token

    repository = Repository.host('GitHub').find_by_full_name(repo_name)
    if repository
      repository.increment!(:stargazers_count)
    else
      RepositoryHost::Github.create(repo_name, token)
    end
  end

  def self.update_from_tag(repo_name, token = nil)
    token ||= AuthToken.token

    repository = Repository.host('GitHub').find_by_full_name(repo_name)
    if repository
      repository.download_tags(token)
    else
      RepositoryHost::Github.create(repo_name, token)
    end
  end

  def github_contributions_count
    contributions_count # legacy alias
  end

  def github_id
    uuid # legacy alias
  end

  def repository_host
    RepositoryHost::Gitlab
    @repository_host ||= RepositoryHost.const_get(host_type.capitalize).new(self)
  end
end