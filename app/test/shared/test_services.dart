// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'package:gcloud/db.dart';
import 'package:gcloud/service_scope.dart';
import 'package:pub_dev/account/models.dart';
import 'package:pub_dev/fake/backend/fake_auth_provider.dart';
import 'package:pub_dev/fake/backend/fake_dartdoc_runner.dart';
import 'package:pub_dev/fake/backend/fake_email_sender.dart';
import 'package:pub_dev/fake/backend/fake_pana_runner.dart';
import 'package:pub_dev/fake/backend/fake_popularity.dart';
import 'package:pub_dev/fake/backend/fake_pub_worker.dart';
import 'package:pub_dev/frontend/handlers/pubapi.client.dart';
import 'package:pub_dev/frontend/static_files.dart';
import 'package:pub_dev/package/name_tracker.dart';
import 'package:pub_dev/search/handlers.dart';
import 'package:pub_dev/search/search_client.dart';
import 'package:pub_dev/search/updater.dart';
import 'package:pub_dev/service/services.dart';
import 'package:pub_dev/shared/configuration.dart';
import 'package:pub_dev/shared/integrity.dart';
import 'package:pub_dev/shared/logging.dart';
import 'package:pub_dev/tool/test_profile/import_source.dart';
import 'package:pub_dev/tool/test_profile/importer.dart';
import 'package:pub_dev/tool/test_profile/models.dart';
import 'package:pub_dev/tool/utils/http_client_to_shelf_handler.dart';
import 'package:pub_dev/tool/utils/pub_api_client.dart';
import 'package:test/test.dart';

import '../shared/utils.dart';
import '../task/fake_time.dart';
import 'handlers_test_utils.dart';
import 'test_models.dart';

export 'package:pub_dev/tool/utils/pub_api_client.dart';

/// Registers test with [name] and runs it in pkg/fake_gcloud's scope, populated
/// with [testProfile] data.
void testWithProfile(
  String name, {
  TestProfile? testProfile,
  ImportSource? importSource,
  required Future<void> Function() fn,
  Timeout? timeout,
  bool processJobsWithFakeRunners = false,
  Pattern? integrityProblem,
  dynamic skip,
}) {
  scopedTest(name, () async {
    setupDebugEnvBasedLogging();
    await withFakeServices(
      fn: () async {
        registerStaticFileCacheForTest(StaticFileCache.forTests());
        registerSearchClient(SearchClient(
            httpClientToShelfHandler(handler: searchServiceHandler)));
        registerScopeExitCallback(searchClient.close);

        await importProfile(
          profile: testProfile ?? defaultTestProfile,
          source: importSource ?? ImportSource.autoGenerated(),
        );
        await nameTracker.reloadFromDatastore();
        await generateFakePopularityValues();
        if (processJobsWithFakeRunners) {
          await processJobsWithFakePanaRunner();
          await processJobsWithFakeDartdocRunner();
          await processTasksWithFakePanaAndDartdoc();
        }
        await indexUpdater.updateAllPackages();
        fakeEmailSender.sentMessages.clear();

        await fork(() async {
          await fn();
        });
        // post-test integrity check
        final problems =
            await IntegrityChecker(dbService).findProblems().toList();
        if (problems.isNotEmpty &&
            (integrityProblem == null ||
                integrityProblem.matchAsPrefix(problems.first) == null)) {
          throw Exception(
              '${problems.length} integrity problems detected. First: ${problems.first}');
        } else if (problems.isEmpty && integrityProblem != null) {
          throw Exception('Integrity problem expected but not present.');
        }
      },
    );
  }, timeout: timeout, skip: skip);
}

/// Execute [fn] with [FakeTime.run] inside [testWithProfile].
void testWithFakeTime(
  String name,
  FutureOr<void> Function(FakeTime fakeTime) fn, {
  TestProfile? testProfile,
  ImportSource? importSource,
  Pattern? integrityProblem,
}) {
  scopedTest(name, () async {
    await FakeTime.run((fakeTime) async {
      setupDebugEnvBasedLogging();
      await withFakeServices(
        fn: () async {
          registerStaticFileCacheForTest(StaticFileCache.forTests());
          registerSearchClient(SearchClient(
              httpClientToShelfHandler(handler: searchServiceHandler)));
          registerScopeExitCallback(searchClient.close);

          await importProfile(
            profile: testProfile ?? defaultTestProfile,
            source: importSource ?? ImportSource.autoGenerated(),
          );
          await nameTracker.reloadFromDatastore();
          await generateFakePopularityValues();
          await indexUpdater.updateAllPackages();
          fakeEmailSender.sentMessages.clear();

          await fork(() async {
            await fn(fakeTime);
          });
          // post-test integrity check
          final problems =
              await IntegrityChecker(dbService).findProblems().toList();
          if (problems.isNotEmpty &&
              (integrityProblem == null ||
                  integrityProblem.matchAsPrefix(problems.first) == null)) {
            throw Exception(
                '${problems.length} integrity problems detected. First: ${problems.first}');
          } else if (problems.isEmpty && integrityProblem != null) {
            throw Exception('Integrity problem expected but not present.');
          }
        },
      );
    });
  });
}

void setupTestsWithCallerAuthorizationIssues(
    Future Function(PubApiClient client) fn) {
  testWithProfile('No active user', fn: () async {
    final rs = fn(createPubApiClient());
    await expectApiException(rs, status: 401, code: 'MissingAuthentication');
  });

  testWithProfile('Active user is not authorized', fn: () async {
    final rs =
        fn(await createFakeAuthPubApiClient(email: 'unauthorized@pub.dev'));
    await expectApiException(rs, status: 403, code: 'InsufficientPermissions');
  });

  testWithProfile('Active user is blocked', fn: () async {
    final users = await dbService.query<User>().run().toList();
    final user = users.firstWhere((u) => u.email == 'admin@pub.dev');
    final client = await createFakeAuthPubApiClient(email: adminAtPubDevEmail);
    await dbService.commit(inserts: [user..isBlocked = true]);
    final rs = fn(client);
    await expectApiException(rs,
        status: 401, code: 'MissingAuthentication', message: 'failed');
  });
}

/// Creates generic test cases for admin API operations with failure expectations
/// (e.g. missing or wrong authentication).
void setupTestsWithAdminTokenIssues(Future Function(PubApiClient client) fn) {
  testWithProfile('No active user', fn: () async {
    final rs = fn(createPubApiClient());
    await expectApiException(rs, status: 401, code: 'MissingAuthentication');
  });

  testWithProfile('Regular user token from the client.', fn: () async {
    final token = createFakeAuthTokenForEmail(
      'unauthorized@pub.dev',
      audience: activeConfiguration.pubClientAudience,
    );
    final rs = fn(createPubApiClient(authToken: token));
    await expectApiException(rs, status: 401, code: 'MissingAuthentication');
  });

  testWithProfile('Regular user token from the website.', fn: () async {
    final token = createFakeAuthTokenForEmail(
      'unauthorized@pub.dev',
      audience: activeConfiguration.pubSiteAudience,
    );
    final rs = fn(createPubApiClient(authToken: token));
    await expectApiException(rs, status: 401, code: 'MissingAuthentication');
  });

  testWithProfile('Regular user token with external audience.', fn: () async {
    final token = createFakeAuthTokenForEmail(
      'unauthorized@pub.dev',
      audience: activeConfiguration.externalServiceAudience,
    );
    final rs = fn(createPubApiClient(authToken: token));
    await expectApiException(rs, status: 401, code: 'MissingAuthentication');
  });

  testWithProfile('Non-admin service agent token', fn: () async {
    final token = createFakeServiceAccountToken(
        email: 'unauthorized@pub.dev', audience: 'https://pub.dev');
    final rs = fn(createPubApiClient(authToken: token));
    await expectApiException(rs, status: 403, code: 'InsufficientPermissions');
  });
}
