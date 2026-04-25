"""
Autocomplete warmer Lambda - builds the search-autocomplete index from TMDB
and writes it to S3.

Triggered weekly by EventBridge. CloudFront serves the resulting JSON files
directly from S3 (path pattern /autocomplete-*.json), avoiding Lambda
invocations on the hot path.
"""
import json
import os

from autocomplete_index import DEFAULT_TARGET_SIZE, build_index
from aws_sigv4 import get_secret, put_s3_object


def get_tmdb_api_key():
    """Load TMDB API key from Secrets Manager."""
    app_secret_arn = os.environ.get('APP_SECRET_ARN')
    if not app_secret_arn:
        raise ValueError("APP_SECRET_ARN not configured")

    secrets = get_secret(app_secret_arn)
    api_key = secrets.get('TMDB_API_KEY')
    if not api_key:
        raise ValueError("TMDB_API_KEY not found in secrets")
    return api_key


def handler(event, context):
    """
    Build autocomplete indexes for each configured locale and write them to S3.

    Output objects:
        s3://<TRENDING_S3_BUCKET>/autocomplete-<locale>.json
    """
    bucket = os.environ.get('TRENDING_S3_BUCKET')
    if not bucket:
        print("ERROR: TRENDING_S3_BUCKET not configured")
        return {"statusCode": 500, "body": "TRENDING_S3_BUCKET not configured"}

    region = os.environ.get('AWS_REGION_NAME', 'us-east-1')
    locales = [
        loc.strip()
        for loc in os.environ.get('AUTOCOMPLETE_LOCALES', 'en').split(',')
        if loc.strip()
    ]
    target_size = int(
        os.environ.get('AUTOCOMPLETE_TARGET_SIZE', str(DEFAULT_TARGET_SIZE))
    )

    try:
        api_key = get_tmdb_api_key()
    except Exception as e:
        print(f"ERROR: Failed to get TMDB API key: {e}")
        return {"statusCode": 500, "body": str(e)}

    results = {}

    for locale in locales:
        print(f"AUTOCOMPLETE_WARMER: Building index for {locale}...")
        try:
            index = build_index(api_key, locale=locale, target_size=target_size)
            json_data = json.dumps(index, separators=(',', ':')).encode('utf-8')

            put_s3_object(
                bucket=bucket,
                key=f"autocomplete-{locale}.json",
                data=json_data,
                region=region,
                content_type='application/json',
                cache_control='public, max-age=86400',
            )

            results[locale] = {
                'status': 'success',
                'items': len(index['items']),
                'bytes': len(json_data),
            }
            print(
                f"AUTOCOMPLETE_WARMER: {locale} - {len(index['items'])} items, "
                f"{len(json_data)} bytes"
            )
        except Exception as e:
            print(f"AUTOCOMPLETE_WARMER: {locale} - Error: {e}")
            results[locale] = {'status': 'error', 'error': str(e)}

    all_success = all(r.get('status') == 'success' for r in results.values())

    summary = {'success': all_success, 'results': results}
    print(
        f"AUTOCOMPLETE_WARMER: Complete - "
        f"{'SUCCESS' if all_success else 'PARTIAL FAILURE'}"
    )

    return {
        'statusCode': 200 if all_success else 500,
        'body': json.dumps(summary),
    }
