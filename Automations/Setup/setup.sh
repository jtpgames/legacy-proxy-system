function create_and_activate_venv_in_current_dir {
  # Check if the "venv" folder exists
  if [ ! -d "venv" ]; then
      echo "The 'venv' folder does not exist. Creating a virtual environment..."
      # Create a virtual environment named "venv"
      python3 -m venv venv

      # Check if the virtual environment was created successfully
      if [ $? -eq 0 ]; then
          echo "Virtual environment 'venv' created successfully."
      else
          echo "Failed to create virtual environment 'venv'. Exiting."
          exit 1
      fi
  else
      echo "The 'venv' folder already exists."
  fi

  # Activate the virtual environment
  source venv/bin/activate

  echo "installing python requirements"
  pip install wheel
  pip install --upgrade pip setuptools
  if [ -f local_requirements.txt ]; then
    pip install -r local_requirements.txt
  else
    pip install -r requirements.txt
  fi

  # Check if the virtual environment was activated successfully
  if [ $? -eq 0 ]; then
      echo "Virtual environment 'venv' activated successfully."
  else
      echo "Failed to activate the virtual environment 'venv'. Exiting."
      exit 2
  fi
}

# move to root folder
cd ../../

echo "Python:"
cd python
create_and_activate_venv_in_current_dir

# move to root folder
cd ..

echo "locust_scripts:"
cd locust_scripts
create_and_activate_venv_in_current_dir

# move to root folder
cd ..

echo "All Python virtual environments created and requirements installed."

echo "Building Docker image for locust_scripts"
docker buildx build -t locust_scripts_runner:latest -f Automations/locust_scripts_runner_dockerfile .

exit 1

cd Automations

# build simulator
echo "Building ARS Simulator ..."
docker buildx build -t simulator_builder -f build_simulator_dockerfile .
docker run --rm -v "$(pwd)/../Simulators:/app" simulator_builder ./gradlew shadowJar -PmainClass=ArsKt

cd ..


