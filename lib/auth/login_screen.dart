import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'student_email.dart';
import 'field_notes.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _signUp = false;
  bool _busy = false;
  bool _obscure = true;
  String? _message;

  static const String _logo = 'assets/icon/UTRGV_GO_removebg.png';

  // Dark blue based on the logo outline.
  static const Color _vgoBlue = Color(0xFF061E4A);

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final client = Supabase.instance.client;
      final email = _email.text.trim().toLowerCase();

      if (_signUp) {
        final response = await client.auth.signUp(
          email: email,
          password: _password.text,
        );

        if (mounted && response.session == null) {
          setState(() {
            _signUp = false;
            _message =
                'Account created. Please confirm your UTRGV email if required, then sign in.';
          });
        }
      } else {
        await client.auth.signInWithPassword(
          email: email,
          password: _password.text,
        );
      }

      _password.clear();
    } on AuthException catch (error) {
      if (mounted) {
        setState(() => _message = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = 'Unable to reach the account service. Try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _toggleMode() {
    if (_busy) return;

    setState(() {
      _signUp = !_signUp;
      _message = null;
      _password.clear();
      _form.currentState?.reset();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        textTheme: Theme.of(context).textTheme.apply(
          fontFamily: 'Inter',
          bodyColor: _vgoBlue,
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: _vgoBlue,
          brightness: Brightness.light,
          primary: _vgoBlue,
          secondary: _vgoBlue,
          surface: journalPaper,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF8F5EB),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          hintStyle: const TextStyle(
            color: Color(0xFF666A66),
            fontSize: 15,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: const BorderSide(color: _vgoBlue),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: const BorderSide(color: _vgoBlue),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: const BorderSide(
              color: _vgoBlue,
              width: 2,
            ),
          ),
          errorMaxLines: 3,
        ),
      ),
      child: Scaffold(
        backgroundColor: journalPaper,
        body: JournalPaper(
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, viewport) {
                return SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: viewport.maxHeight,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 28,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(
                                child: Image.asset(
                                  _logo,
                                  width: 280,
                                  fit: BoxFit.contain,
                                  semanticLabel: 'UTRGV-GO logo',
                                ),
                              ),

                              const SizedBox(height: 28),

                              Form(
                                key: _form,
                                child: AutofillGroup(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        'UTRGV email',
                                        style: journalType(
                                          20,
                                          color: _vgoBlue,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      TextFormField(
                                        controller: _email,
                                        enabled: !_busy,
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        textInputAction: TextInputAction.next,
                                        autocorrect: false,
                                        style: const TextStyle(
                                          color: _vgoBlue,
                                          fontSize: 16,
                                        ),
                                        autofillHints: const [
                                          AutofillHints.email,
                                        ],
                                        decoration: const InputDecoration(
                                          hintText: 'name@utrgv.edu',
                                        ),
                                        validator: (value) {
                                          if (StudentEmail.isEligible(
                                            value ?? '',
                                          )) {
                                            return null;
                                          }

                                          return 'Use your UTRGV email address (@utrgv.edu).';
                                        },
                                      ),

                                      const SizedBox(height: 22),

                                      Text(
                                        'Password',
                                        style: journalType(
                                          20,
                                          color: _vgoBlue,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      TextFormField(
                                        controller: _password,
                                        enabled: !_busy,
                                        obscureText: _obscure,
                                        textInputAction: TextInputAction.done,
                                        style: const TextStyle(
                                          color: _vgoBlue,
                                          fontSize: 16,
                                        ),
                                        autofillHints: [
                                          _signUp
                                              ? AutofillHints.newPassword
                                              : AutofillHints.password,
                                        ],
                                        decoration: InputDecoration(
                                          hintText: _signUp
                                              ? 'At least 8 characters'
                                              : 'Enter your password',
                                          suffixIcon: IconButton(
                                            tooltip: _obscure
                                                ? 'Show password'
                                                : 'Hide password',
                                            onPressed: _busy
                                                ? null
                                                : () {
                                                    setState(() {
                                                      _obscure = !_obscure;
                                                    });
                                                  },
                                            icon: Icon(
                                              _obscure
                                                  ? Icons.visibility_outlined
                                                  : Icons.visibility_off_outlined,
                                              color: _vgoBlue,
                                            ),
                                          ),
                                        ),
                                        validator: (value) {
                                          if (value == null || value.isEmpty) {
                                            return 'Enter your password.';
                                          }

                                          if (_signUp && value.length < 8) {
                                            return 'Use at least 8 characters.';
                                          }

                                          return null;
                                        },
                                        onFieldSubmitted: (_) => _submit(),
                                      ),

                                      if (_message != null)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 18),
                                          child: Semantics(
                                            liveRegion: true,
                                            child: Text(
                                              _message!,
                                              style: const TextStyle(
                                                color: _vgoBlue,
                                              ),
                                            ),
                                          ),
                                        ),

                                      const SizedBox(height: 26),

                                      FilledButton(
                                        onPressed: _busy ? null : _submit,
                                        style: FilledButton.styleFrom(
                                          backgroundColor: _vgoBlue,
                                          foregroundColor: journalPaper,
                                          minimumSize:
                                              const Size.fromHeight(56),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(5),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            const SizedBox(width: 32),
                                            Expanded(
                                              child: Text(
                                                _busy
                                                    ? 'Please wait...'
                                                    : _signUp
                                                        ? 'Create account'
                                                        : 'Sign in',
                                                textAlign: TextAlign.center,
                                                style: journalType(
                                                  23,
                                                  color: journalPaper,
                                                ),
                                              ),
                                            ),
                                            Container(
                                              width: 32,
                                              height: 32,
                                              decoration: const BoxDecoration(
                                                color: _vgoBlue,
                                                shape: BoxShape.circle,
                                              ),
                                              child: _busy
                                                  ? const Padding(
                                                      padding:
                                                          EdgeInsets.all(8),
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.white,
                                                      ),
                                                    )
                                                  : const Icon(
                                                      Icons.arrow_forward,
                                                      color: Colors.white,
                                                    ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      const SizedBox(height: 18),

                                      Wrap(
                                        alignment: WrapAlignment.center,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            _signUp
                                                ? 'Already exploring?'
                                                : 'New here?',
                                            style: journalType(
                                              16,
                                              color: _vgoBlue,
                                            ),
                                          ),
                                          TextButton(
                                            onPressed:
                                                _busy ? null : _toggleMode,
                                            child: Text(
                                              _signUp
                                                  ? 'Sign in'
                                                  : 'Create an account',
                                              style: journalType(
                                                16,
                                                color: _vgoBlue,
                                              ).copyWith(
                                                decoration:
                                                    TextDecoration.underline,
                                                decorationColor: _vgoBlue,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              const SizedBox(height: 16),

                              Divider(
                                color: _vgoBlue.withValues(alpha: 0.35),
                              ),

                              const SizedBox(height: 14),

                              const Text(
                                'Only @utrgv.edu email addresses accepted.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: _vgoBlue,
                                  fontSize: 10,
                                  letterSpacing: 1.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}