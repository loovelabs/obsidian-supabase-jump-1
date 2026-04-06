// ============================================================================
// LOOVE OS Edge Function: generate-embedding
// ============================================================================
// Processes the embedding_jobs queue, generates embeddings for vault_files
// rows using Supabase's built-in AI inference (gte-small model).
//
// Deploy: supabase functions deploy generate-embedding
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(supabaseUrl, supabaseServiceKey);

const EMBEDDING_MODEL = "gte-small"; // 384 dimensions

interface EmbeddingJob {
  msg_id: number;
  message: {
    id: string;
    table: string;
    content_column: string;
    embedding_column: string;
  };
}

async function generateEmbedding(text: string): Promise<number[]> {
  const response = await fetch(
    `${supabaseUrl}/functions/v1/ai/embedding`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${supabaseServiceKey}`,
      },
      body: JSON.stringify({
        model: EMBEDDING_MODEL,
        input: text,
      }),
    }
  );

  if (!response.ok) {
    const { data, error } = await supabase.functions.invoke("ai", {
      body: {
        model: EMBEDDING_MODEL,
        input: text,
        task: "embedding",
      },
    });

    if (error) throw new Error(`Embedding generation failed: ${error.message}`);
    return data.embedding;
  }

  const data = await response.json();
  return data.embedding;
}

function truncateContent(content: string, maxTokens: number = 8000): string {
  // Strip frontmatter first
  const stripped = content.replace(/^---[\s\S]*?---\s*\n/, "");
  const maxChars = maxTokens * 4;
  return stripped.length > maxChars
    ? stripped.substring(0, maxChars)
    : stripped;
}

Deno.serve(async (req) => {
  try {
    const { queue = "embedding_jobs", batch_size = 10 } = await req.json();

    const { data: messages, error: readError } = await supabase.rpc(
      "pgmq_read",
      {
        queue_name: queue,
        vt: 60,
        qty: batch_size,
      }
    );

    if (readError) {
      console.error("Queue read error:", readError);
      return new Response(JSON.stringify({ error: readError.message }), {
        status: 500,
      });
    }

    if (!messages || messages.length === 0) {
      return new Response(JSON.stringify({ processed: 0 }), { status: 200 });
    }

    let processed = 0;
    let failed = 0;

    for (const msg of messages as EmbeddingJob[]) {
      try {
        const { id, table: tableName, content_column, embedding_column } =
          msg.message;

        const { data: row, error: fetchError } = await supabase
          .from(tableName)
          .select(`${content_column}, ${embedding_column}`)
          .eq("id", id)
          .single();

        if (fetchError || !row) {
          console.error(`Row fetch error for ${id}:`, fetchError);
          failed++;
          continue;
        }

        if (row[embedding_column]) {
          await supabase.rpc("pgmq_delete", {
            queue_name: queue,
            msg_id: msg.msg_id,
          });
          processed++;
          continue;
        }

        const content = row[content_column];
        if (!content || content.trim().length === 0) {
          await supabase.rpc("pgmq_delete", {
            queue_name: queue,
            msg_id: msg.msg_id,
          });
          processed++;
          continue;
        }

        const truncated = truncateContent(content);
        const embedding = await generateEmbedding(truncated);

        const { error: updateError } = await supabase
          .from(tableName)
          .update({ [embedding_column]: embedding })
          .eq("id", id);

        if (updateError) {
          console.error(`Update error for ${id}:`, updateError);
          failed++;
          continue;
        }

        await supabase.rpc("pgmq_delete", {
          queue_name: queue,
          msg_id: msg.msg_id,
        });

        processed++;
      } catch (err) {
        console.error(`Processing error for msg ${msg.msg_id}:`, err);
        failed++;
      }
    }

    return new Response(
      JSON.stringify({ processed, failed, total: messages.length }),
      { status: 200 }
    );
  } catch (err) {
    console.error("Function error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
    });
  }
});
