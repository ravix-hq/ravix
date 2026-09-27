defmodule RavixWeb.OnboardingComponents do
  @moduledoc "A small, explorable example of describing a change, reviewing it, and continuing the same thread."
  use RavixWeb, :html

  attr :id, :string, required: true

  def workflow_preview(assigns) do
    ~H"""
    <section class="workflow-preview" aria-label="A look inside Ravix">
      <div class="workflow-caption">
        <.icon name="branch" size={15} />Ravix<span>Example workspace</span>
      </div>
      <details name={@id} open>
        <summary>Describe the change</summary>
        <div class="workflow-scene">
          <div class="example-project">
            <.icon name="github" size={15} />acme / website<span class="chip">Search</span>
          </div>
          <p class="example-prompt">Add search to the projects page.</p>
          <div class="example-reply">
            <.icon name="sparkle" size={16} /><p>
              I’ll add a search field, filter the projects, and test the empty state.
            </p>
          </div>
          <div class="example-branch">
            <.icon name="branch" size={13} /><code>ravix/project-search</code>
          </div>
          <p class="scene-note">
            You describe the task. Ravix opens a branch, and the agent starts there.
          </p>
        </div>
      </details>
      <details name={@id}>
        <summary>Review the work</summary>
        <div class="workflow-scene">
          <div class="example-project">
            <.icon name="branch" size={15} />Project search<span class="chip">Review</span>
          </div>
          <h3>Read the diff, then open the running app.</h3>
          <div class="example-diff">
            <span>projects.tsx</span><code>+ &lt;SearchField onChange=&#123;setQuery&#125; /&gt;</code><code>+ &lt;ProjectList query=&#123;query&#125; /&gt;</code>
          </div>
          <p class="scene-note">
            The diff sits next to the conversation. The preview is the app, already running.
          </p>
        </div>
      </details>
      <details name={@id}>
        <summary>Bring someone into the same thread</summary>
        <div class="workflow-scene">
          <div class="example-project">
            <.icon name="add-person" size={15} />Project search<span class="chip">Shared track</span>
          </div>
          <h3>They prompt the same agent.</h3>
          <p class="example-prompt">Can we search by project owner too?</p>
          <div class="example-reply">
            <.icon name="sparkle" size={16} /><p>I’ll include the owner in the search results.</p>
          </div>
          <p class="scene-note">
            Share the track. They continue the thread, with the earlier decisions still there.
          </p>
        </div>
      </details>
    </section>
    """
  end
end
