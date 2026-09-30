defmodule RavixWeb.OnboardingComponents do
  @moduledoc """
  A small, explorable example of describing a change, reviewing it, and
  continuing the same thread: three numbered steps, one open at a time.

  Every class here has a rule under "how it works" in `assets/css/app.css`,
  and `browser/first-run.spec.js` checks the section is drawn with them, so
  the example cannot go back to bare disclosure triangles unnoticed.
  """
  use RavixWeb, :html

  attr :id, :string, required: true

  def workflow_preview(assigns) do
    ~H"""
    <section id={@id} class="workflow-preview" aria-label="A look inside Ravix">
      <details name={@id} class="workflow-step" open>
        <summary>
          <span class="workflow-num" aria-hidden="true">1</span>
          <span class="workflow-title">Describe the change</span>
          <.icon name="chevron" size={13} class="workflow-chevron" />
        </summary>
        <div class="workflow-scene">
          <div class="example-project">
            <.icon name="github" size={14} />
            <span>acme / website</span>
            <span class="chip">Search</span>
          </div>
          <p class="example-prompt">Add search to the projects page.</p>
          <div class="example-reply">
            <.icon name="sparkle" size={14} />
            <p>I’ll add a search field, filter the projects, and test the empty state.</p>
          </div>
          <div class="example-branch">
            <.icon name="branch" size={13} /><code>ravix/project-search</code>
          </div>
          <p class="scene-note">
            You describe the task. Ravix opens a branch, and the agent starts there.
          </p>
        </div>
      </details>
      <details name={@id} class="workflow-step">
        <summary>
          <span class="workflow-num" aria-hidden="true">2</span>
          <span class="workflow-title">Review the work</span>
          <.icon name="chevron" size={13} class="workflow-chevron" />
        </summary>
        <div class="workflow-scene">
          <div class="example-project">
            <.icon name="branch" size={14} />
            <span>Project search</span>
            <span class="chip">Review</span>
          </div>
          <h3>Read the diff, then open the running app.</h3>
          <div class="example-diff">
            <span>projects.tsx</span>
            <code>+ &lt;SearchField onChange=&#123;setQuery&#125; /&gt;</code>
            <code>+ &lt;ProjectList query=&#123;query&#125; /&gt;</code>
          </div>
          <p class="scene-note">
            The diff sits next to the conversation. The preview is the app, already running.
          </p>
        </div>
      </details>
      <details name={@id} class="workflow-step">
        <summary>
          <span class="workflow-num" aria-hidden="true">3</span>
          <span class="workflow-title">Bring someone into the same thread</span>
          <.icon name="chevron" size={13} class="workflow-chevron" />
        </summary>
        <div class="workflow-scene">
          <div class="example-project">
            <.icon name="add-person" size={14} />
            <span>Project search</span>
            <span class="chip">Shared track</span>
          </div>
          <h3>They prompt the same agent.</h3>
          <p class="example-prompt">Can we search by project owner too?</p>
          <div class="example-reply">
            <.icon name="sparkle" size={14} />
            <p>I’ll include the owner in the search results.</p>
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
