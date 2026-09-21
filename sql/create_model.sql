\set chat_model       'nhtsa_chat'

-- SELECT aidb.create_model(
--     'my_embeddings_model',
--     'openai_embeddings',
--     config => '{
--         "model": "text-embedding-3-small",
--         "url": "https://<your-resource>.cognitiveservices.azure.com/openai/v1/embeddings"
--     }'::jsonb,
--     credentials_env => 'AIDB_AZURE_OPENAI_API_KEY'
-- );

SELECT aidb.create_model(
    'nhtsa_chat',
    'openai_responses_azure',
    aidb.openai_responses_config(
        model             => 'gpt-5.4-mini',
        url               => 'https://<your-resource>.cognitiveservices.azure.com/openai/v1/responses',
        temperature       => 0.1,
        max_output_tokens => 2048
    ),
    credentials_env     => 'AIDB_AZURE_OPENAI_API_KEY',   -- AIDB_ prefix REQUIRED
    replace_credentials => true,   -- 03 already set the provider creds; reuse/overwrite
    validate            => false
) AS chat_model;